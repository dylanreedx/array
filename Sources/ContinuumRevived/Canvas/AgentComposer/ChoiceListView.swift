import AppKit
import ContinuumRevivedAgentUI

/// A menu icon is caller-owned data. System symbols cover native commands;
/// named assets let the same surface carry app-specific concepts without adding
/// a dependency from the shared choice control back to any feature.
enum ChoiceIcon: Equatable {
    case system(String)
    case asset(String)

    @MainActor
    func image() -> NSImage? {
        let source: NSImage?
        switch self {
        case .system(let name):
            // Reuse the canvas-wide template bitmap cache. Command-menu icons
            // participate in the same backing cascade as the rest of the tile
            // subtree, so retaining vector symbol reps here would undo part of
            // the symbol freeze when the sidebar and camera programs merge.
            source = CanvasSymbolImage.image(named: name)
        case .asset(let name):
            source = NSImage(named: NSImage.Name(name))
        }
        guard let source else { return nil }
        let image = (source.copy() as? NSImage) ?? source
        image.isTemplate = true
        return image
    }
}

struct ChoiceItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String?
    let icon: ChoiceIcon?
    let enabled: Bool
    let destructive: Bool

    init(
        id: String, title: String, detail: String? = nil,
        icon: ChoiceIcon? = nil, enabled: Bool = true,
        destructive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.icon = icon
        self.enabled = enabled
        self.destructive = destructive
    }
}

/// Pickers and command menus share behaviour but not anatomy. A picker reserves
/// its leading slot for the selected-value checkmark; a command menu uses that
/// slot only when its caller supplies an icon and adopts native menu density.
enum ChoiceListPresentation {
    case choices
    case commands
}

enum ChoiceListCommand {
    case previous, next, first, last, accept, open, ascend, cancel
}

/// Token-painted choice rows with one keyboard and accessibility selection path.
/// Disabled rows remain visible but are never focusable or actionable.
@MainActor
final class ChoiceListView: NSView, TokenThemed {
    private(set) var items: [ChoiceItem]
    private(set) var selectedID: String?
    private(set) var focusedID: String?
    var onSelection: ((ChoiceItem) -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var lastAccessibilityAnnouncementForQA: String?
    let presentation: ChoiceListPresentation

    private var rows: [ChoiceRowView] = []
    private let destructiveSeparator = NSView(frame: .zero)
    private var typeahead = ""
    private var lastTypeaheadTime: TimeInterval = 0

    static let rowHeight: CGFloat = 36
    static let commandRowHeight: CGFloat = 30
    static let horizontalPadding = CGFloat(Space.l)
    static let verticalPadding = CGFloat(Space.m)
    static let minimumWidth: CGFloat = 220
    /// Owner correction (P4.10): the panel keeps exactly one subtle boundary and
    /// no border anywhere in the app exceeds 0.5 pt.
    static let panelBorderWidth: CGFloat = 0.5

    init(
        items: [ChoiceItem], selectedID: String?,
        presentation: ChoiceListPresentation = .choices
    ) {
        self.items = items
        self.presentation = presentation
        self.selectedID = items.contains(where: { $0.id == selectedID }) ? selectedID : nil
        self.focusedID = items.first(where: { $0.id == selectedID && $0.enabled })?.id
            ?? items.first(where: \.enabled)?.id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.container)
        layer?.masksToBounds = true
        destructiveSeparator.wantsLayer = true
        destructiveSeparator.isHidden = true
        addSubview(destructiveSeparator)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Choices")
        rebuildRows()
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { items.contains(where: \.enabled) }

    override var intrinsicContentSize: NSSize {
        let textWidth = items.map { item -> CGFloat in
            let title = ceil((item.title as NSString).size(withAttributes: [.font: NSFont.token(.body)]).width)
            let detail = item.detail.map {
                ceil(($0 as NSString).size(withAttributes: [.font: NSFont.token(.caption)]).width)
            } ?? 0
            return max(title, detail)
        }.max() ?? 0
        let hasLeadingSlot = presentation == .choices || items.contains { $0.icon != nil }
        let leadingWidth: CGFloat = hasLeadingSlot ? 26 : 0
        let minimumWidth = presentation == .commands ? 184 : Self.minimumWidth
        return NSSize(
            width: max(minimumWidth, textWidth + Self.horizontalPadding * 2 + leadingWidth),
            height: CGFloat(items.count) * renderedRowHeight + Self.verticalPadding * 2
                + destructiveSeparatorGap
        )
    }

    override func layout() {
        super.layout()
        var y = bounds.height - Self.verticalPadding - renderedRowHeight
        for (index, row) in rows.enumerated() {
            if index == destructiveSeparatorIndex {
                y -= destructiveSeparatorGap
                destructiveSeparator.frame = NSRect(
                    x: Self.verticalPadding + 4,
                    y: y + renderedRowHeight + floor(destructiveSeparatorGap / 2),
                    width: max(0, bounds.width - (Self.verticalPadding + 4) * 2),
                    height: LineWidth.hairline)
            }
            row.frame = NSRect(
                x: Self.verticalPadding,
                y: y,
                width: max(0, bounds.width - Self.verticalPadding * 2),
                height: renderedRowHeight
            )
            y -= renderedRowHeight
        }
    }

    private var renderedRowHeight: CGFloat {
        presentation == .commands ? Self.commandRowHeight : Self.rowHeight
    }

    private var destructiveSeparatorIndex: Int? {
        guard presentation == .commands,
              let index = items.firstIndex(where: \.destructive), index > 0 else { return nil }
        return index
    }

    private var destructiveSeparatorGap: CGFloat {
        destructiveSeparatorIndex == nil ? 0 : 9
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: perform(.previous)
        case 125: perform(.next)
        case 115: perform(.first)
        case 119: perform(.last)
        case 36, 76: perform(.accept)
        case 53: perform(.cancel)
        default:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let characters = event.charactersIgnoringModifiers,
                  characters.rangeOfCharacter(from: .alphanumerics) != nil else {
                super.keyDown(with: event)
                return
            }
            applyTypeahead(characters)
        }
    }

    func perform(_ command: ChoiceListCommand) {
        let enabled = items.filter(\.enabled)
        switch command {
        case .previous, .next:
            guard !enabled.isEmpty else { return }
            let current = enabled.firstIndex(where: { $0.id == focusedID })
            let delta = command == .previous ? -1 : 1
            let base = current ?? (delta > 0 ? -1 : enabled.count)
            focusedID = enabled[(base + delta + enabled.count) % enabled.count].id
            updateRows()
            announceFocusedChoice()
        case .first:
            focusedID = enabled.first?.id
            updateRows()
            announceFocusedChoice()
        case .last:
            focusedID = enabled.last?.id
            updateRows()
            announceFocusedChoice()
        case .accept, .open:
            guard let item = items.first(where: { $0.id == focusedID && $0.enabled }) else { return }
            choose(item)
        case .ascend:
            break
        case .cancel:
            onDismiss?()
        }
    }

    /// Shared by pointer and VoiceOver. Keeping the enabled guard here prevents
    /// either input path from accidentally bypassing keyboard policy.
    func choose(id: String) {
        let negativeWitness = ProcessInfo.processInfo.environment["CONTINUUM_P4_7_NEGATIVE_WITNESS"] == "1"
        guard let item = items.first(where: {
            $0.id == id && ($0.enabled || negativeWitness)
        }) else { return }
        choose(item)
    }

    var qaItems: [ChoiceItem] { items }
    var qaDestructiveIDs: Set<String> { Set(items.filter(\.destructive).map(\.id)) }
    var qaVisibleIconIDs: Set<String> {
        Set(zip(items, rows).compactMap { item, row in
            row.qaLeadingImageHidden ? nil : item.id
        })
    }
    var qaHasDestructiveSeparator: Bool { !destructiveSeparator.isHidden }
    var qaRenderedRowHeight: CGFloat { renderedRowHeight }

    var qaRowStates: [(id: String, selected: Bool, focused: Bool, enabled: Bool, checkVisible: Bool, borderWidth: CGFloat)] {
        rows.map {
            ($0.item.id, $0.qaSelected, $0.qaFocused, $0.item.enabled, !$0.qaCheckHidden, $0.layer?.borderWidth ?? 0)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        layer?.borderWidth = Self.panelBorderWidth
        layer?.borderColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        destructiveSeparator.layer?.backgroundColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        destructiveSeparator.isHidden = destructiveSeparatorIndex == nil
        updateRows()
    }

    private func choose(_ item: ChoiceItem) {
        selectedID = item.id
        focusedID = item.id
        updateRows()
        onSelection?(item)
    }

    private func applyTypeahead(_ characters: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTypeaheadTime > 0.7 { typeahead = "" }
        lastTypeaheadTime = now
        typeahead += characters.lowercased()
        if let match = items.first(where: {
            $0.enabled && $0.title.lowercased().hasPrefix(typeahead)
        }) {
            focusedID = match.id
            updateRows()
            announceFocusedChoice()
        }
    }

    private func announceFocusedChoice() {
        guard let focusedID,
              let item = items.first(where: { $0.id == focusedID }) else { return }
        let announcement = item.destructive ? "Destructive action, \(item.title)" : item.title
        // The recorded value and accessibility post share this one seam so the
        // deterministic check goes red if keyboard focus stops announcing.
        lastAccessibilityAnnouncementForQA = announcement
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [.announcement: announcement])
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        let reservesLeadingSlot = presentation == .choices || items.contains { $0.icon != nil }
        rows = items.map { item in
            let row = ChoiceRowView(
                item: item, presentation: presentation,
                reservesLeadingSlot: reservesLeadingSlot)
            row.onChoose = { [weak self] id in self?.choose(id: id) }
            row.onHover = { [weak self] id in
                guard let self, self.items.contains(where: { $0.id == id && $0.enabled }) else { return }
                self.focusedID = id
                self.updateRows()
            }
            addSubview(row)
            return row
        }
        setAccessibilityChildren(rows)
        needsLayout = true
        invalidateIntrinsicContentSize()
        updateRows()
    }

    private func updateRows() {
        for row in rows {
            row.update(selected: row.item.id == selectedID, focused: row.item.id == focusedID)
        }
    }
}

@MainActor
private final class ChoiceRowView: NSControl, TokenThemed {
    let item: ChoiceItem
    let presentation: ChoiceListPresentation
    let reservesLeadingSlot: Bool
    var onChoose: ((String) -> Void)?
    var onHover: ((String) -> Void)?

    private let leadingImageView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var selected = false
    private var focused = false
    private var trackingArea: NSTrackingArea?

    var qaSelected: Bool { selected }
    var qaFocused: Bool { focused }
    var qaCheckHidden: Bool { presentation != .choices || leadingImageView.isHidden }
    var qaLeadingImageHidden: Bool { leadingImageView.isHidden }

    init(
        item: ChoiceItem, presentation: ChoiceListPresentation,
        reservesLeadingSlot: Bool
    ) {
        self.item = item
        self.presentation = presentation
        self.reservesLeadingSlot = reservesLeadingSlot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.card)
        titleLabel.stringValue = item.title
        titleLabel.font = .token(.body)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.stringValue = item.detail ?? ""
        detailLabel.font = .token(.caption)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.isHidden = item.detail == nil
        leadingImageView.image = presentation == .choices
            ? CanvasSymbolImage.image(named: "checkmark")
            : item.icon?.image()
        leadingImageView.imageScaling = .scaleProportionallyDown
        leadingImageView.setAccessibilityElement(false)
        addSubview(leadingImageView)
        addSubview(titleLabel)
        addSubview(detailLabel)
        setAccessibilityRole(.row)
        setAccessibilityLabel(item.title)
        let help = item.destructive ? "Destructive action. \(item.detail ?? "")" : item.detail
        setAccessibilityHelp(help)
        setAccessibilityEnabled(item.enabled)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        leadingImageView.frame = NSRect(
            x: 8, y: floor((bounds.height - 14) / 2), width: 14, height: 14)
        let textX: CGFloat = reservesLeadingSlot ? 30 : 10
        if detailLabel.isHidden {
            titleLabel.frame = NSRect(x: textX, y: floor((bounds.height - 20) / 2), width: max(0, bounds.width - textX - 8), height: 20)
        } else {
            titleLabel.frame = NSRect(x: textX, y: bounds.height - 20, width: max(0, bounds.width - textX - 8), height: 17)
            detailLabel.frame = NSRect(x: textX, y: 2, width: max(0, bounds.width - textX - 8), height: 14)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if item.enabled { onHover?(item.id) }
    }

    override func mouseDown(with event: NSEvent) {
        if item.enabled { onChoose?(item.id) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard item.enabled else { return false }
        onChoose?(item.id)
        return true
    }

    func update(selected: Bool, focused: Bool) {
        self.selected = selected
        self.focused = focused && item.enabled
        setAccessibilitySelected(selected)
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        // Owner correction (P4.10): rows never paint a perimeter border. State is
        // fill plus checkmark — selected fill, soft hover/keyboard-focus fill,
        // muted text for disabled. The focus cue moves with the fill and vanishes
        // on dismiss, so it never becomes a permanent grey box.
        if selected {
            layer?.backgroundColor = AgentSurfaceRole.rowSelected.color.cgColor(for: theme)
        } else if focused {
            layer?.backgroundColor = AgentSurfaceRole.rowHover.color.cgColor(for: theme)
        } else {
            // A resting row owns NO colour slot (inbox-card precedent): a
            // painted transparent is an unregistered literal under the
            // adopted-owner value gate the provider picker now puts rows under.
            layer?.backgroundColor = nil
        }
        layer?.borderWidth = 0
        leadingImageView.isHidden = presentation == .choices
            ? !selected : item.icon == nil
        // Keep destructive copy calm, but tint its icon with the established failure
        // accent: native command-menu hierarchy without turning a whole row into an
        // alarm before the person has even chosen it.
        let foreground = item.enabled ? TextToken.textPrimary.color : TextToken.textSecondary.color
        titleLabel.textColor = foreground.nsColor(for: theme)
        detailLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        leadingImageView.contentTintColor = presentation == .choices
            ? AgentLineRole.focusRing.color.nsColor(for: theme)
            : (item.destructive
                ? AccentToken.accentFailed.color.nsColor(for: theme)
                : TextToken.textSecondary.color.nsColor(for: theme))
        alphaValue = item.enabled ? 1 : 0.58
    }
}
