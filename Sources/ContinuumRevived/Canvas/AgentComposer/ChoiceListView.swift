import AppKit
import ContinuumRevivedAgentUI

/// A menu icon is caller-owned data. System symbols cover native commands;
/// named assets let the same surface carry app-specific concepts without adding
/// a dependency from the shared choice control back to any feature.
enum ChoiceIcon: Equatable {
    case system(String)
    case asset(String)
    case provider(String)

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
        case .provider(let model):
            if model == "pi" {
                source = BrandMark96.load("pi")
            } else {
                source = BrandMark96.mark(forModel: model) ?? CanvasSymbolImage.image(named: "cpu")
            }
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
    let toolTip: String?
    // Plan: .plans/86-workspace-filter/README.md — the `.checklist` anatomy.
    /// The row's checkbox. Only a checklist draws it.
    var check: ChoiceCheck? = nil
    /// A colour dot before the title (a workspace's colour).
    var swatch: NSColor? = nil
    /// A right-aligned caption ("Array", "1 headless").
    var trailing: String? = nil
    /// A small accent dot at the trailing edge: something here needs you.
    var attention = false
    /// A divider above this row.
    var separatorBefore = false
    /// Choosing this row leaves the popover open (a checkbox, not a pick).
    var keepsOpen = false
    /// Buttons the row shows while it is hovered or focused, trailing edge first.
    var accessories: [ChoiceAccessory] = []
    /// The accessory Option-click presses (`Only`).
    var optionAccessoryID: String? = nil

    init(
        id: String, title: String, detail: String? = nil,
        icon: ChoiceIcon? = nil, enabled: Bool = true,
        destructive: Bool = false, toolTip: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.icon = icon
        self.enabled = enabled
        self.destructive = destructive
        self.toolTip = toolTip
    }
}

enum ChoiceCheck: Equatable {
    case on, off, mixed
    /// Checked by implication rather than by choice: drawn faint.
    case following
}

/// A hover button on a checklist row: a text pill (`Only`) or a symbol (`…`).
struct ChoiceAccessory: Equatable {
    let id: String
    let title: String?
    let symbol: String?
    let accessibilityLabel: String
}

/// Pickers and command menus share behaviour but not anatomy. A picker reserves
/// its leading slot for the selected-value checkmark; a command menu uses that
/// slot only when its caller supplies an icon and adopts native menu density.
enum ChoiceListPresentation {
    case choices
    /// Compact checked rows for window-chrome menus, with section dividers.
    case compactChoices
    case commands
    /// Prompt commands carry explanatory copy, unlike compact sidebar menus.
    case slashCommands
    case completions
    /// Checkboxes over a set: rows toggle without closing, carry a colour dot,
    /// a trailing caption and hover accessories, and size to their own content
    /// (30pt, or 36pt with a detail line), with dividers between sections.
    case checklist

    var showsSelectionCheckmark: Bool { self == .choices || self == .compactChoices }
}

enum ChoiceListChrome {
    case standalone
    case embedded
}

enum ChoiceListCommand {
    case previous, next, first, last, accept, open, ascend, cancel
    /// Backspace in a passive completion panel. The composer decides whether
    /// it climbs out of a folder or deletes text; a list has nothing to do.
    case deleteBackward
}

/// Token-painted choice rows with one keyboard and accessibility selection path.
/// Disabled rows remain visible but are never focusable or actionable.
@MainActor
final class ChoiceListView: NSView, TokenThemed, AgentPageZoomScalable {
    private(set) var items: [ChoiceItem]
    private(set) var selectedID: String?
    private(set) var focusedID: String?
    var onSelection: ((ChoiceItem) -> Void)?
    var onDismiss: (() -> Void)?
    /// A row's hover accessory was pressed, or Option-click pressed its option accessory.
    var onAccessory: ((ChoiceItem, String) -> Void)?
    /// The focused row changed under the pointer or the keyboard; nil when the
    /// pointer leaves the list.
    var onFocusChange: ((String?) -> Void)?
    private(set) var lastAccessibilityAnnouncementForQA: String?
    let presentation: ChoiceListPresentation
    let chrome: ChoiceListChrome

    private var rows: [ChoiceRowView] = []
    private let destructiveSeparator = NSView(frame: .zero)
    private var sectionSeparators: [NSView] = []
    private var listTrackingArea: NSTrackingArea?
    private var typeahead = ""
    /// WS5: the page zoom this list draws at. The list lives in a PANEL, not in
    /// the tile's subtree, so its owner forwards the rung explicitly.
    private(set) var pageZoom: AgentPageZoom = .default
    private var lastTypeaheadTime: TimeInterval = 0

    static let rowHeight: CGFloat = 36
    static let commandRowHeight: CGFloat = 30
    static let slashCommandRowHeight: CGFloat = 40
    static let horizontalPadding = CGFloat(Space.l)
    static let verticalPadding = CGFloat(Space.m)
    static let minimumWidth: CGFloat = 220
    /// Owner correction (P4.10): the panel keeps exactly one subtle boundary and
    /// no border anywhere in the app exceeds 0.5 pt.
    static let panelBorderWidth: CGFloat = 0.5

    /// WS5: the same metrics at a page zoom. The `static let`s above are kept so
    /// callers outside a zoomed surface keep compiling; these are the same
    /// values scaled, and exact identities at 100%. `panelBorderWidth` has no
    /// zoomed form on purpose — a hairline is a device property, not a metric.
    static func rowHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(36)) }
    static func commandRowHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(30)) }
    static func slashCommandRowHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(40)) }
    static func horizontalPadding(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.l)) }
    static func verticalPadding(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(Space.m)) }
    static func minimumWidth(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(220)) }

    init(
        items: [ChoiceItem], selectedID: String?,
        presentation: ChoiceListPresentation = .choices,
        chrome: ChoiceListChrome = .standalone
    ) {
        self.items = items
        self.presentation = presentation
        self.chrome = chrome
        self.selectedID = items.contains(where: { $0.id == selectedID }) ? selectedID : nil
        // A checklist opens with nothing lit: the boxes already say what is chosen,
        // and a highlighted first row would read as one more.
        self.focusedID = presentation == .checklist ? nil
            : items.first(where: { $0.id == selectedID && $0.enabled })?.id
            ?? items.first(where: \.enabled)?.id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.applyCorner(.popover, zoom: pageZoom)
        layer?.masksToBounds = true
        destructiveSeparator.wantsLayer = true
        destructiveSeparator.isHidden = true
        addSubview(destructiveSeparator)
        setAccessibilityRole(.list)
        setAccessibilityElement(true)
        setAccessibilityLabel("Choices")
        rebuildRows()
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { items.contains(where: \.enabled) }

    override var intrinsicContentSize: NSSize {
        // What a row's LABEL needs, measured the way a label draws (the cell's own
        // inset included), not the way `NSString.size` measures a glyph run.
        let textWidth = items.map { item -> CGFloat in
            let title = ChoiceLabelMetrics.labelWidth(
                for: item.title, font: .token(.body, zoom: pageZoom))
            let detail = item.detail.map {
                ChoiceLabelMetrics.labelWidth(for: $0, font: .token(.caption, zoom: pageZoom))
            } ?? 0
            guard presentation == .checklist else { return max(title, detail) }
            return max(title + ChoiceRowView.swatchReserve(item, zoom: pageZoom), detail)
                + ChoiceRowView.trailingReserve(item, zoom: pageZoom)
        }.max() ?? 0
        let minimumWidth = presentation == .commands
            ? CGFloat(pageZoom.scaled(184)) : Self.minimumWidth(zoom: pageZoom)
        let height = [.checklist, .compactChoices].contains(presentation)
            ? items.map(rowHeight(for:)).reduce(0, +) + CGFloat(separatorIndices.count) * sectionGap
            : CGFloat(items.count) * renderedRowHeight + destructiveSeparatorGap
        return NSSize(
            width: max(minimumWidth, textWidth + rowChromeWidth),
            height: height + renderedVerticalPadding * 2
        )
    }

    /// A checklist row is as tall as its content; every other list is uniform.
    private func rowHeight(for item: ChoiceItem) -> CGFloat {
        guard presentation == .checklist else { return renderedRowHeight }
        return item.detail == nil ? Self.commandRowHeight(zoom: pageZoom) : Self.rowHeight(zoom: pageZoom)
    }

    /// Rows a sectioned list draws a divider above.
    private var separatorIndices: [Int] {
        guard [.checklist, .compactChoices].contains(presentation) else { return [] }
        return items.indices.filter { $0 > 0 && items[$0].separatorBefore }
    }

    private var sectionGap: CGFloat { CGFloat(pageZoom.scaled(9)) }

    /// Everything between the panel's edges and a row's label, taken from the
    /// SAME expressions `layout()` and `ChoiceRowView.layout()` use. Sizing the
    /// panel from a separately invented padding pair (`horizontalPadding * 2` plus
    /// a 26pt leading slot) left each row's label about 8pt short of its own
    /// title, so every row ellipsized at every panel width.
    private var rowChromeWidth: CGFloat {
        renderedRowInset * 2
            + ChoiceRowView.textInset(reservesLeadingSlot: reservesLeadingSlot, zoom: pageZoom)
            + ChoiceRowView.trailingInset(zoom: pageZoom)
    }

    private var reservesLeadingSlot: Bool {
        ![.commands, .slashCommands].contains(presentation) || items.contains { $0.icon != nil }
    }

    override func layout() {
        super.layout()
        if [.checklist, .compactChoices].contains(presentation) {
            layoutSectionedRows()
            return
        }
        var y = bounds.height - renderedVerticalPadding - renderedRowHeight
        let rowInset = renderedRowInset
        for (index, row) in rows.enumerated() {
            if index == destructiveSeparatorIndex {
                y -= destructiveSeparatorGap
                let separatorInset = rowInset + CGFloat(pageZoom.scaled(4))
                destructiveSeparator.frame = NSRect(
                    x: separatorInset,
                    y: y + renderedRowHeight + floor(destructiveSeparatorGap / 2),
                    width: max(0, bounds.width - separatorInset * 2),
                    height: LineWidth.hairline)
            }
            row.frame = NSRect(
                x: rowInset,
                y: y,
                width: max(0, bounds.width - rowInset * 2),
                height: renderedRowHeight
            )
            y -= renderedRowHeight
        }
    }

    private func layoutSectionedRows() {
        var top = bounds.height - renderedVerticalPadding
        let rowInset = renderedRowInset
        let dividers = Set(separatorIndices)
        var separatorIndex = 0
        for (index, row) in rows.enumerated() {
            if dividers.contains(index) {
                let separatorInset = rowInset + CGFloat(pageZoom.scaled(4))
                if separatorIndex < sectionSeparators.count {
                    sectionSeparators[separatorIndex].frame = NSRect(
                        x: separatorInset, y: top - floor(sectionGap / 2),
                        width: max(0, bounds.width - separatorInset * 2), height: LineWidth.hairline)
                }
                separatorIndex += 1
                top -= sectionGap
            }
            let height = rowHeight(for: row.item)
            row.frame = NSRect(x: rowInset, y: top - height, width: max(0, bounds.width - rowInset * 2), height: height)
            top -= height
        }
    }

    private var renderedRowHeight: CGFloat {
        switch presentation {
        case .commands, .compactChoices:
            // A command row that carries a subtitle needs the two-line height.
            // Every row of the list takes it, so a menu never mixes 30pt and 40pt
            // rows; at 30pt the title and subtitle of the zone cancel menu's
            // "Keep Choosing" row overlapped by seven points.
            return items.contains(where: { $0.detail != nil })
                ? Self.slashCommandRowHeight(zoom: pageZoom)
                : Self.commandRowHeight(zoom: pageZoom)
        case .slashCommands: return Self.slashCommandRowHeight(zoom: pageZoom)
        case .choices, .completions, .checklist: return Self.rowHeight(zoom: pageZoom)
        }
    }

    private var renderedVerticalPadding: CGFloat {
        presentation == .completions
            ? CGFloat(pageZoom.scaled(4)) : Self.verticalPadding(zoom: pageZoom)
    }

    /// The horizontal inset `layout()` gives every row. It has always been the
    /// VERTICAL padding token (not `horizontalPadding`); the name is preserved
    /// here so the scaled form cannot quietly change which token it reads.
    private var renderedRowInset: CGFloat { Self.verticalPadding(zoom: pageZoom) }

    private var destructiveSeparatorIndex: Int? {
        guard [.commands, .slashCommands].contains(presentation),
              let index = items.firstIndex(where: \.destructive), index > 0 else { return nil }
        return index
    }

    private var destructiveSeparatorGap: CGFloat {
        destructiveSeparatorIndex == nil ? 0 : CGFloat(pageZoom.scaled(9))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: perform(.previous)
        case 125: perform(.next)
        case 115: perform(.first)
        case 119: perform(.last)
        case 36, 76: perform(.accept)
        case 49 where presentation == .checklist: perform(.accept)
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
            scrollFocusedRowToVisible()
            announceFocusedChoice()
            onFocusChange?(focusedID)
        case .first:
            focusedID = enabled.first?.id
            updateRows()
            scrollFocusedRowToVisible()
            announceFocusedChoice()
        case .last:
            focusedID = enabled.last?.id
            updateRows()
            scrollFocusedRowToVisible()
            announceFocusedChoice()
        case .accept, .open:
            guard let item = items.first(where: { $0.id == focusedID && $0.enabled }) else { return }
            choose(item)
        case .ascend, .deleteBackward:
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
    var qaAccessibilityLabels: [String] {
        rows.compactMap { $0.accessibilityLabel() }
    }
    var qaHasDestructiveSeparator: Bool { !destructiveSeparator.isHidden }
    var qaRenderedRowHeight: CGFloat { renderedRowHeight }
    /// The row height this list lays out with, for the panel that sizes to it.
    var layoutRowHeight: CGFloat { renderedRowHeight }
    var qaRowTitleColors: [(id: String, color: NSColor?)] {
        rows.map { ($0.item.id, $0.qaTitleColor) }
    }
    var qaRowTextFrames: [(title: NSRect, detail: NSRect?)] {
        rows.map { ($0.qaTitleFrame, $0.qaDetailFrame) }
    }
    /// Every row whose title its own label cell cannot draw whole at the width
    /// it was laid out with — measured from the installed label, never from the
    /// expression the list sized itself with.
    var qaTruncatedRowTitles: [String] {
        rows.filter { !$0.qaTitleDrawsWhole }.map(\.item.title)
    }
    var qaFocusedRowIsVisible: Bool {
        guard let focusedID,
              let row = rows.first(where: { $0.item.id == focusedID }),
              let scrollView = enclosingScrollView else { return true }
        return scrollView.documentVisibleRect.contains(row.frame)
    }

    func scrollFocusedRowToVisible() {
        guard let focusedID,
              let row = rows.first(where: { $0.item.id == focusedID }) else { return }
        layoutSubtreeIfNeeded()
        row.scrollToVisible(row.bounds)
    }

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
        layer?.applyCorner(.popover, zoom: pageZoom)
        let theme = effectiveTokenTheme
        layer?.backgroundColor = chrome == .standalone
            ? SurfaceToken.overlay.color.cgColor(for: theme) : nil
        layer?.borderWidth = chrome == .standalone ? Self.panelBorderWidth : 0
        layer?.borderColor = chrome == .standalone
            ? AgentLineRole.decorativeHairline.color.cgColor(for: theme) : nil
        destructiveSeparator.layer?.backgroundColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        destructiveSeparator.isHidden = destructiveSeparatorIndex == nil
        for separator in sectionSeparators {
            separator.layer?.backgroundColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        }
        updateRows()
    }

    /// WS5: re-derive every zoom-owned metric from scratch and pass the rung down
    /// to the rows, which own their own text and glyph metrics.
    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        layer?.applyCorner(.popover, zoom: pageZoom)
        for row in rows { row.applyPageZoom(pageZoom) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func choose(_ item: ChoiceItem) {
        // A checklist's state is its checkboxes; a selected fill would be a second,
        // contradicting answer to "what is chosen".
        if presentation != .checklist { selectedID = item.id }
        focusedID = item.id
        updateRows()
        onSelection?(item)
    }

    /// New items for an open checklist — the boxes after a toggle, the counts after
    /// a push — keeping the focused row where it is.
    func replace(items next: [ChoiceItem]) {
        guard next != items else { return }
        let inPlace = rows.count == next.count && zip(rows, next).allSatisfy { $0.refresh(with: $1) }
        items = next
        if !items.contains(where: { $0.id == focusedID && $0.enabled }) {
            focusedID = presentation == .checklist ? nil : items.first(where: \.enabled)?.id
        }
        if inPlace {
            invalidateIntrinsicContentSize()
            needsLayout = true
            updateRows()
        } else {
            rebuildRows()
            applyTokens()
        }
    }

    func pressAccessory(itemID: String, accessoryID: String) {
        guard let item = items.first(where: { $0.id == itemID && $0.enabled }),
              item.accessories.contains(where: { $0.id == accessoryID }) || item.optionAccessoryID == accessoryID
        else { return }
        onAccessory?(item, accessoryID)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let listTrackingArea { removeTrackingArea(listTrackingArea) }
        guard presentation == .checklist else { return }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        listTrackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        guard presentation == .checklist else { return super.mouseExited(with: event) }
        onFocusChange?(nil)
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
            scrollFocusedRowToVisible()
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
        let reservesLeadingSlot = self.reservesLeadingSlot
        rows = items.map { item in
            let row = ChoiceRowView(
                item: item, presentation: presentation,
                reservesLeadingSlot: reservesLeadingSlot)
            row.onChoose = { [weak self] id in self?.choose(id: id) }
            row.onHover = { [weak self] id in
                guard let self, self.items.contains(where: { $0.id == id && $0.enabled }) else { return }
                let changed = self.focusedID != id
                self.focusedID = id
                self.updateRows()
                self.scrollFocusedRowToVisible()
                if changed || self.presentation == .checklist { self.onFocusChange?(id) }
            }
            row.onAccessory = { [weak self] id, accessory in self?.pressAccessory(itemID: id, accessoryID: accessory) }
            row.applyPageZoom(pageZoom)
            addSubview(row)
            return row
        }
        setAccessibilityChildren(rows)
        sectionSeparators.forEach { $0.removeFromSuperview() }
        sectionSeparators = separatorIndices.map { _ in
            let separator = NSView(frame: .zero)
            separator.wantsLayer = true
            addSubview(separator)
            return separator
        }
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
private final class ChoiceRowView: NSControl, TokenThemed, AgentPageZoomScalable {
    private(set) var item: ChoiceItem
    let presentation: ChoiceListPresentation
    let reservesLeadingSlot: Bool
    var onChoose: ((String) -> Void)?
    var onHover: ((String) -> Void)?
    var onAccessory: ((String, String) -> Void)?

    private let leadingImageView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    // `.checklist` only. Dots are drawn, not layer fills: a palette colour is
    // the caller's data, not a token this row owns.
    private let swatchDot = ChoiceDotView()
    private let attentionDot = ChoiceDotView()
    private let trailingLabel = NSTextField(labelWithString: "")
    private var accessoryButtons: [ChoiceAccessoryButton] = []
    private var selected = false
    private var focused = false
    private var trackingArea: NSTrackingArea?
    /// WS5: the rung this row draws at, pushed down by its list.
    private(set) var pageZoom: AgentPageZoom = .default

    var qaSelected: Bool { selected }
    var qaFocused: Bool { focused }
    var qaCheckHidden: Bool { !presentation.showsSelectionCheckmark || leadingImageView.isHidden }
    var qaLeadingImageHidden: Bool { leadingImageView.isHidden }
    var qaTitleFrame: NSRect { titleLabel.frame }
    var qaTitleDrawsWhole: Bool {
        titleLabel.frame.width + 0.5 >= ChoiceLabelMetrics.drawingWidth(of: titleLabel)
    }
    var qaDetailFrame: NSRect? { detailLabel.isHidden ? nil : detailLabel.frame }
    var qaTitleColor: NSColor? { titleLabel.textColor }

    init(
        item: ChoiceItem, presentation: ChoiceListPresentation,
        reservesLeadingSlot: Bool
    ) {
        self.item = item
        self.presentation = presentation
        self.reservesLeadingSlot = reservesLeadingSlot
        super.init(frame: .zero)
        wantsLayer = true
        layer?.applyCorner(.card, zoom: pageZoom)
        titleLabel.stringValue = item.title
        titleLabel.font = .token(.body, zoom: pageZoom)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.stringValue = item.detail ?? ""
        detailLabel.font = .token(.caption, zoom: pageZoom)
        detailLabel.lineBreakMode = presentation == .completions
            ? .byTruncatingMiddle : .byTruncatingTail
        detailLabel.isHidden = item.detail == nil
        leadingImageView.image = item.icon?.image() ?? (presentation.showsSelectionCheckmark
            ? CanvasSymbolImage.image(named: "checkmark") : nil)
        leadingImageView.imageScaling = .scaleProportionallyDown
        leadingImageView.setAccessibilityElement(false)
        addSubview(leadingImageView)
        addSubview(titleLabel)
        addSubview(detailLabel)
        if presentation == .checklist {
            swatchDot.isHidden = item.swatch == nil
            attentionDot.isHidden = !item.attention
            trailingLabel.stringValue = item.trailing ?? ""
            trailingLabel.font = .token(.caption, zoom: pageZoom)
            trailingLabel.alignment = .right
            trailingLabel.isHidden = item.trailing == nil
            trailingLabel.setAccessibilityElement(false)
            accessoryButtons = item.accessories.map { accessory in
                let button = ChoiceAccessoryButton(accessory: accessory)
                button.onPress = { [weak self] id in
                    guard let self else { return }
                    self.onAccessory?(self.item.id, id)
                }
                button.isHidden = true
                return button
            }
            [swatchDot, attentionDot, trailingLabel].forEach(addSubview)
            accessoryButtons.forEach(addSubview)
        }
        setAccessibilityRole(.row)
        setAccessibilityElement(true)
        setAccessibilityLabel([item.title, item.detail, item.trailing].compactMap { $0 }.joined(separator: ", "))
        if let check = item.check {
            setAccessibilityRole(.checkBox)
            setAccessibilityValue(check == .off ? 0 : (check == .mixed ? 2 : 1))
        }
        toolTip = item.toolTip
        let detailHelp = item.destructive ? "Destructive action. \(item.detail ?? "")" : item.detail
        let help = item.toolTip.map { [detailHelp, $0].compactMap { $0 }.joined(separator: "\n") } ?? detailHelp
        setAccessibilityHelp(help)
        setAccessibilityEnabled(item.enabled)
        setAccessibilitySelected(selected)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The row's leading text inset. Static so the LIST can size its panel from
    /// the same number the row lays its label out with.
    static func textInset(reservesLeadingSlot: Bool, zoom: AgentPageZoom) -> CGFloat {
        reservesLeadingSlot ? CGFloat(zoom.scaled(30)) : CGFloat(zoom.scaled(10))
    }

    static func trailingInset(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(8)) }

    static func swatchSide(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(7)) }

    /// The dot and its gap before a checklist title.
    static func swatchReserve(_ item: ChoiceItem, zoom: AgentPageZoom) -> CGFloat {
        item.swatch == nil ? 0 : swatchSide(zoom: zoom) + CGFloat(zoom.scaled(6))
    }

    /// Room kept at a checklist row's trailing edge for whichever is wider: its
    /// caption, or the accessories that replace it on hover.
    static func trailingReserve(_ item: ChoiceItem, zoom: AgentPageZoom) -> CGFloat {
        let gap = CGFloat(zoom.scaled(Space.m))
        let caption = item.trailing.map {
            ChoiceLabelMetrics.labelWidth(for: $0, font: .token(.caption, zoom: zoom)) + gap
        } ?? (item.attention ? CGFloat(zoom.scaled(14)) : 0)
        let accessories = item.accessories.reduce(CGFloat(0)) {
            $0 + ChoiceAccessoryButton.width(for: $1, zoom: zoom) + CGFloat(zoom.scaled(4))
        }
        return max(caption, accessories == 0 ? 0 : accessories + gap)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTokens()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func layout() {
        super.layout()
        let glyphSide = CGFloat(pageZoom.scaled(14))
        let leadingX = CGFloat(pageZoom.scaled(8))
        leadingImageView.frame = NSRect(
            x: leadingX, y: floor((bounds.height - glyphSide) / 2), width: glyphSide, height: glyphSide)
        let textX = Self.textInset(reservesLeadingSlot: reservesLeadingSlot, zoom: pageZoom)
        let trailingInset = Self.trailingInset(zoom: pageZoom)
        if presentation == .checklist {
            layoutChecklist(textX: textX, trailingInset: trailingInset)
            return
        }
        let textWidth = max(0, bounds.width - textX - trailingInset)
        if detailLabel.isHidden {
            let singleHeight = CGFloat(pageZoom.scaled(20))
            titleLabel.frame = NSRect(x: textX, y: floor((bounds.height - singleHeight) / 2), width: textWidth, height: singleHeight)
        } else {
            // Title over subtitle as ONE block, centred in the row. The old
            // layout pinned the title 20pt below the top and the subtitle 2pt
            // above the bottom, so the pair only cleared each other in a row at
            // least 33pt tall — a 30pt command row put the title's baseline
            // inside the subtitle.
            let titleHeight = CGFloat(pageZoom.scaled(17))
            let detailHeight = CGFloat(pageZoom.scaled(14))
            let gap = CGFloat(pageZoom.scaled(Space.xs))
            let block = titleHeight + gap + detailHeight
            let bottom = max(0, floor((bounds.height - block) / 2))
            detailLabel.frame = NSRect(x: textX, y: bottom, width: textWidth, height: detailHeight)
            titleLabel.frame = NSRect(
                x: textX, y: bottom + detailHeight + gap, width: textWidth, height: titleHeight)
        }
    }

    private func layoutChecklist(textX: CGFloat, trailingInset: CGFloat) {
        let reserve = Self.trailingReserve(item, zoom: pageZoom)
        let swatch = Self.swatchReserve(item, zoom: pageZoom)
        let titleHeight = CGFloat(pageZoom.scaled(detailLabel.isHidden ? 20 : 17))
        let detailHeight = CGFloat(pageZoom.scaled(14))
        let gap = CGFloat(pageZoom.scaled(Space.xs))
        let block = detailLabel.isHidden ? titleHeight : titleHeight + gap + detailHeight
        let bottom = max(0, floor((bounds.height - block) / 2))
        let titleY = detailLabel.isHidden ? bottom : bottom + detailHeight + gap
        let titleWidth = max(0, bounds.width - textX - swatch - trailingInset - reserve)
        titleLabel.frame = NSRect(x: textX + swatch, y: titleY, width: titleWidth, height: titleHeight)
        detailLabel.frame = NSRect(x: textX, y: bottom,
                                   width: max(0, bounds.width - textX - trailingInset - reserve), height: detailHeight)
        let side = Self.swatchSide(zoom: pageZoom)
        swatchDot.frame = NSRect(x: textX, y: titleLabel.frame.midY - side / 2 - 0.5, width: side, height: side)
        let attention = CGFloat(pageZoom.scaled(6))
        attentionDot.frame = NSRect(x: bounds.width - trailingInset - attention, y: floor((bounds.height - attention) / 2),
                                    width: attention, height: attention)
        let captionHeight = CGFloat(pageZoom.scaled(14))
        trailingLabel.frame = NSRect(x: textX, y: floor((bounds.height - captionHeight) / 2),
                                     width: max(0, bounds.width - textX - trailingInset), height: captionHeight)
        var x = bounds.width - CGFloat(pageZoom.scaled(4))
        let buttonHeight = CGFloat(pageZoom.scaled(20))
        for button in accessoryButtons {
            let width = ChoiceAccessoryButton.width(for: button.accessory, zoom: pageZoom)
            x -= width
            button.frame = NSRect(x: x, y: floor((bounds.height - buttonHeight) / 2), width: width, height: buttonHeight)
            x -= CGFloat(pageZoom.scaled(4))
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
        guard item.enabled else { return }
        if event.modifierFlags.contains(.option), let only = item.optionAccessoryID {
            onAccessory?(item.id, only)
            return
        }
        onChoose?(item.id)
    }

    override func accessibilityPerformPress() -> Bool {
        guard item.enabled else { return false }
        onChoose?(item.id)
        return true
    }

    /// WS5: re-derive every zoom-owned metric from scratch. Idempotent, and safe
    /// on a row already showing its item.
    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        layer?.applyCorner(.card, zoom: pageZoom)
        titleLabel.font = .token(.body, zoom: pageZoom)
        detailLabel.font = .token(.caption, zoom: pageZoom)
        trailingLabel.font = .token(.caption, zoom: pageZoom)
        accessoryButtons.forEach { $0.pageZoom = zoom }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func update(selected: Bool, focused: Bool) {
        self.selected = selected
        self.focused = focused && item.enabled
        setAccessibilitySelected(selected)
        applyTokens()
    }

    func applyTokens() {
        layer?.applyCorner(.card, zoom: pageZoom)
        let theme = effectiveTokenTheme
        // Owner correction (P4.10): rows never paint a perimeter border. State is
        // fill plus checkmark — selected fill, soft hover/keyboard-focus fill,
        // muted text for disabled. The focus cue moves with the fill and vanishes
        // on dismiss, so it never becomes a permanent grey box.
        if selected && presentation != .checklist {
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
        leadingImageView.isHidden = presentation.showsSelectionCheckmark ? (item.icon == nil && !selected) : item.icon == nil
        if presentation == .checklist { applyChecklistTokens(theme: theme) }
        // A destructive command reads as one in its title and its icon: the
        // failure accent, which is the app's destructive colour. The row's FILL
        // stays the ordinary hover ladder, so nothing alarms before it is chosen.
        let foreground = !item.enabled ? TextToken.textSecondary.color
            : item.destructive ? AccentToken.accentFailed.color : TextToken.textPrimary.color
        titleLabel.textColor = foreground.nsColor(for: theme)
        detailLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        leadingImageView.contentTintColor = presentation.showsSelectionCheckmark
            ? AgentLineRole.focusRing.color.nsColor(for: theme)
            : (item.destructive
                ? AccentToken.accentFailed.color.nsColor(for: theme)
                : TextToken.textSecondary.color.nsColor(for: theme))
        alphaValue = item.enabled ? 1 : 0.58
    }

    private func applyChecklistTokens(theme: TokenTheme) {
        let check = item.check ?? .off
        let symbol: String
        switch check {
        case .on, .following: symbol = "checkmark.square.fill"
        case .mixed: symbol = "minus.square.fill"
        case .off: symbol = "square"
        }
        if item.check == nil {
            // A PICK in a checklist (it replaces rather than combines): the
            // caller's icon — a checkmark on the chosen one — never a box.
            leadingImageView.image = item.icon?.image()
            leadingImageView.isHidden = item.icon == nil
            leadingImageView.contentTintColor = AgentLineRole.focusRing.color.nsColor(for: theme)
            leadingImageView.alphaValue = 1
        } else {
            leadingImageView.image = CanvasSymbolImage.image(named: symbol)
            leadingImageView.isHidden = false
            leadingImageView.contentTintColor = (check == .off ? TextToken.textSecondary : TextToken.textPrimary)
                .color.nsColor(for: theme)
            leadingImageView.alphaValue = check == .following ? 0.38 : (check == .off ? 0.7 : 1)
        }
        swatchDot.colour = item.swatch
        attentionDot.colour = AccentToken.accentApproval.color.nsColor(for: theme)
        trailingLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        // The accessories replace the caption and the attention dot while the
        // row is the one under the pointer or the keyboard.
        let showsAccessories = focused && !accessoryButtons.isEmpty
        accessoryButtons.forEach { $0.isHidden = !showsAccessories }
        trailingLabel.isHidden = item.trailing == nil || showsAccessories
        attentionDot.isHidden = !item.attention || showsAccessories || item.trailing != nil
    }

    /// The same row in a new state — a checklist toggle changes boxes, captions
    /// and counts, never which rows exist. False when the anatomy differs, and the
    /// list rebuilds the row instead.
    func refresh(with next: ChoiceItem) -> Bool {
        guard next.id == item.id, next.enabled == item.enabled, next.destructive == item.destructive,
              (next.detail == nil) == (item.detail == nil), (next.trailing == nil) == (item.trailing == nil),
              (next.swatch == nil) == (item.swatch == nil), (next.check == nil) == (item.check == nil),
              next.accessories == item.accessories, next.separatorBefore == item.separatorBefore
        else { return false }
        guard next != item else { return true }
        item = next
        titleLabel.stringValue = next.title
        detailLabel.stringValue = next.detail ?? ""
        trailingLabel.stringValue = next.trailing ?? ""
        setAccessibilityLabel([next.title, next.detail, next.trailing].compactMap { $0 }.joined(separator: ", "))
        if let check = next.check { setAccessibilityValue(check == .off ? 0 : (check == .mixed ? 2 : 1)) }
        toolTip = next.toolTip
        needsLayout = true
        applyTokens()
        return true
    }

    var qaAccessoriesVisible: Bool { accessoryButtons.contains { !$0.isHidden } }
    var qaCheckImageAlpha: CGFloat { leadingImageView.alphaValue }
}

/// A filled circle in a caller's colour, drawn rather than layer-filled.
@MainActor
final class ChoiceDotView: NSView {
    var colour: NSColor? { didSet { needsDisplay = true } }
    /// A rounded bar instead of a circle (a sidebar card's workspace mark).
    var isRounded = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let colour else { return }
        colour.setFill()
        if isRounded {
            let radius = min(bounds.width, bounds.height) / 2
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        } else {
            NSBezierPath(ovalIn: bounds).fill()
        }
    }
}

/// A checklist row's hover button: the `Only` pill or the `…` symbol. Drawn,
/// with the row hover ladder's next step under the pointer.
@MainActor
final class ChoiceAccessoryButton: NSControl {
    let accessory: ChoiceAccessory
    var onPress: ((String) -> Void)?
    var pageZoom: AgentPageZoom = .default { didSet { needsDisplay = true } }
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    init(accessory: ChoiceAccessory) {
        self.accessory = accessory
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessory.accessibilityLabel)
        toolTip = accessory.accessibilityLabel
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func width(for accessory: ChoiceAccessory, zoom: AgentPageZoom) -> CGFloat {
        if let title = accessory.title {
            return ceil(ChoiceLabelMetrics.labelWidth(for: title, font: .token(.caption, zoom: zoom))) + CGFloat(zoom.scaled(14))
        }
        return CGFloat(zoom.scaled(22))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onPress?(accessory.id) }
    override func accessibilityPerformPress() -> Bool { onPress?(accessory.id); return true }

    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        let radius = bounds.height / 2
        let fill = (hovered ? AgentSurfaceRole.rowSelected : AgentSurfaceRole.composer).color.nsColor(for: theme)
        if accessory.title != nil || hovered {
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let ink = TextToken.textPrimary.color.nsColor(for: theme)
        if let title = accessory.title {
            let text = NSAttributedString(string: title, attributes: [
                .font: NSFont.token(.caption, zoom: pageZoom), .foregroundColor: ink])
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        } else if let symbol = accessory.symbol, let image = CanvasSymbolImage.image(named: symbol) {
            // Fit by aspect: `ellipsis` is wide and short, and a square squashes it.
            let side = CGFloat(pageZoom.scaled(12))
            let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
            let size = aspect >= 1 ? NSSize(width: side, height: side / aspect) : NSSize(width: side * aspect, height: side)
            let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height)
            let tinted = NSImage(size: rect.size, flipped: false) { drawRect in
                image.draw(in: drawRect)
                TextToken.textSecondary.color.nsColor(for: theme).set()
                drawRect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
        }
    }
}
