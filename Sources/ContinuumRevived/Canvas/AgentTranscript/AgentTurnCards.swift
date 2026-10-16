import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Which grammar the transcript renders (`.plans/70` S8).
///
/// Three redesigns of the old grammar were received as "looks the same",
/// because every change went into row internals inside one fixed skeleton.
/// Direction C changes the skeleton: the TURN is the unit (Ask, work strip,
/// answer, outcome), earlier turns fold to one line, and the work is a live
/// line under the prompt instead of a gyro at the foot of the scroll.
///
/// Dylan has not yet chosen between directions A, B and C, so the turn-card
/// rendering hangs off exactly this one value. `.rows` is the previous grammar,
/// untouched and still witnessed by `--transcript-rhythm-check`; flipping
/// `current` back reverts the whole direction.
enum AgentTranscriptPresentationStyle: Equatable {
    case rows
    case turnCards

    /// THE switch point. Read once per transcript, at construction. Defaulted
    /// to `.rows` for now: under `.turnCards` the row-grammar witnesses
    /// (`--transcript-rhythm-check`, the page-zoom overflow sweep) still need
    /// migrating before C can ship as the default.
    @MainActor static var current: AgentTranscriptPresentationStyle = .rows
}

/// The turn card's measures at 100%, each scaled by the tile's page zoom.
/// Values come from the direction C previews (`TurnsC`, `StreamC`).
enum AgentTurnCardMetrics {
    /// Left and right air around the reading column.
    static let columnInset: CGFloat = 20
    /// The reading measure: `min(width - 40, 640)`.
    static let maximumColumnWidth: CGFloat = 640
    static let askLineHeight: CGFloat = 20
    static let askClampLines = 2
    static let stripLineHeight: CGFloat = 22
    static let stripVerticalPadding: CGFloat = 6
    static let stripHorizontalPadding: CGFloat = 10
    static let foldedVerticalPadding: CGFloat = 6
    static let foldedAskLineHeight: CGFloat = 18
    static let foldedOutcomeLineHeight: CGFloat = 16
    static let foldedLineGap: CGFloat = 3
    static let chipHeight: CGFloat = 24
    static let chipGap: CGFloat = 6
    static let chipHorizontalPadding: CGFloat = 8
    /// Between two turns (the rule sits in the middle of it).
    static let turnGap: CGFloat = 20
    /// Between the parts of one card: Ask → strip → answer → outcome.
    static let cardGap: CGFloat = 12
    /// Between the rows of an opened work log.
    static let logGap: CGFloat = 2
    /// The activity barcode: one tick per step.
    static let tickWidth: CGFloat = 3
    static let tickHeight: CGFloat = 10
    static let tickGap: CGFloat = 2
    static let maximumTicks = 40

    static func scaled(_ value: CGFloat, _ zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.scaled(Double(value)))
    }

    static func stripHeight(zoom: AgentPageZoom) -> CGFloat {
        scaled(stripLineHeight + stripVerticalPadding * 2, zoom)
    }

    static func foldedHeight(zoom: AgentPageZoom) -> CGFloat {
        scaled(foldedVerticalPadding * 2 + foldedAskLineHeight + foldedLineGap + foldedOutcomeLineHeight, zoom)
    }

    static func askFont(zoom: AgentPageZoom) -> NSFont { .token(.title, zoom: zoom) }
    static func metaFont(zoom: AgentPageZoom) -> NSFont { .token(.label, zoom: zoom) }
    static func stripFont(zoom: AgentPageZoom) -> NSFont {
        .systemFont(ofSize: NSFont.token(.body, zoom: zoom).pointSize, weight: .medium)
    }
    static func foldedAskFont(zoom: AgentPageZoom) -> NSFont {
        .systemFont(ofSize: NSFont.token(.body, zoom: zoom).pointSize, weight: .semibold)
    }
    static func outcomeFont(zoom: AgentPageZoom) -> NSFont {
        .systemFont(ofSize: scaled(12, zoom), weight: .regular)
    }
    static func chipFont(zoom: AgentPageZoom) -> NSFont {
        .monospacedSystemFont(ofSize: NSFont.token(.label, zoom: zoom).pointSize, weight: .regular)
    }
}

/// One step on the activity barcode, coloured by what kind of step it was.
enum AgentWorkTick: Equatable {
    case look
    case edit
    case run
    case delegate
    case failed

    static func of(toolName: String?, failed: Bool) -> AgentWorkTick {
        if failed { return .failed }
        switch AgentToolKind.resolve(toolName: toolName) {
        case .edit, .todo: return .edit
        case .shell: return .run
        case .delegate: return .delegate
        case .read, .search, .fetch, .unknown: return .look
        }
    }

    func color(_ theme: TokenTheme) -> NSColor {
        switch self {
        case .look: return TextToken.textSecondary.color.nsColor(for: theme).withAlphaComponent(0.5)
        case .edit: return AccentToken.accentReview.color.nsColor(for: theme)
        case .run: return AccentToken.accentWorking.color.nsColor(for: theme)
        case .delegate: return AccentToken.accentInput.color.nsColor(for: theme)
        case .failed: return AccentToken.accentFailed.color.nsColor(for: theme)
        }
    }
}

/// What a turn's state reads as, wherever the turn is drawn.
enum AgentTurnTone: Equatable {
    case working
    case done
    case stopped
    case failed

    var glyph: String {
        switch self {
        case .working: return "\u{25D0}"
        case .done: return "\u{2713}"
        case .stopped: return "\u{25A0}"
        case .failed: return "\u{2715}"
        }
    }

    var accent: AccentToken? {
        switch self {
        case .working: return .accentWorking
        case .done: return .accentDone
        case .failed: return .accentFailed
        case .stopped: return nil
        }
    }

    func glyphColor(_ theme: TokenTheme) -> NSColor {
        accent?.color.nsColor(for: theme) ?? TextToken.textSecondary.color.nsColor(for: theme)
    }

    /// The strip's fill: the state's accent at a whisper.
    func fillColor(_ theme: TokenTheme) -> NSColor {
        guard let accent else {
            return TextToken.textSecondary.color.nsColor(for: theme).withAlphaComponent(0.06)
        }
        return accent.color.nsColor(for: theme).withAlphaComponent(self == .working ? 0.07 : 0.05)
    }
}

struct AgentWorkStripModel: Equatable {
    var tone: AgentTurnTone
    /// One line, never empty while the turn is open.
    var text: String
    var ticks: [AgentWorkTick]
    var countText: String?
    var hasWork: Bool
    var isExpanded: Bool
}

struct AgentTurnAskModel: Equatable {
    var text: String
    var timeText: String?
    var isExpanded: Bool
    /// An earlier turn opened in place: the Ask offers to fold it again.
    var canFold: Bool
}

struct AgentFoldedTurnModel: Equatable {
    var askText: String
    var timeText: String?
    var tone: AgentTurnTone
    var outcomeText: String
}

struct AgentTurnOutcomeModel: Equatable {
    struct Chip: Equatable {
        var title: String
        var added: UInt?
        var removed: UInt?
        var blockID: AgentNodeID
    }

    var chips: [Chip]
}

// MARK: - Collection item

/// One collection item for every turn-card piece. The views are list-owned in
/// the same way the cluster header is: text is re-driven directly on a tick,
/// never through a snapshot reload.
@MainActor
final class AgentTurnCardItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AgentTurnCardItem")

    private(set) var askView: AgentTurnAskView?
    private(set) var stripView: AgentWorkStripView?
    private(set) var foldedView: AgentFoldedTurnView?
    private(set) var outcomeView: AgentTurnOutcomeView?

    override func loadView() {
        view = NSView(frame: .zero)
    }

    private func adopt<V: NSView>(_ made: V) -> V {
        made.frame = view.bounds
        made.autoresizingMask = [.width, .height]
        view.addSubview(made)
        return made
    }

    private func reset() {
        view.subviews.forEach { $0.removeFromSuperview() }
        askView = nil
        stripView = nil
        foldedView = nil
        outcomeView = nil
    }

    func installAsk() -> AgentTurnAskView {
        if let askView, askView.superview === view { return askView }
        reset()
        let made = adopt(AgentTurnAskView(frame: .zero))
        askView = made
        return made
    }

    func installStrip() -> AgentWorkStripView {
        if let stripView, stripView.superview === view { return stripView }
        reset()
        let made = adopt(AgentWorkStripView(frame: .zero))
        stripView = made
        return made
    }

    func installFolded() -> AgentFoldedTurnView {
        if let foldedView, foldedView.superview === view { return foldedView }
        reset()
        let made = adopt(AgentFoldedTurnView(frame: .zero))
        foldedView = made
        return made
    }

    func installOutcome() -> AgentTurnOutcomeView {
        if let outcomeView, outcomeView.superview === view { return outcomeView }
        reset()
        let made = adopt(AgentTurnOutcomeView(frame: .zero))
        outcomeView = made
        return made
    }

    /// The piece this item currently shows, for accessibility ordering.
    var hostedView: NSView? { askView ?? stripView ?? foldedView ?? outcomeView }

    override func prepareForReuse() {
        super.prepareForReuse()
        reset()
    }
}

// MARK: - Ask

/// The user's prompt as the turn's heading: 15pt semibold, two lines, then
/// "more". No container and no rule — speaker contrast comes from type.
@MainActor
final class AgentTurnAskView: NSView {
    private(set) var textLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var timeLabel = NSTextField(labelWithString: "")
    private(set) var moreLabel = NSTextField(labelWithString: "")
    private(set) var foldLabel = NSTextField(labelWithString: "")
    private(set) var model = AgentTurnAskModel(text: "", timeText: nil, isExpanded: false, canFold: false)
    private var zoom: AgentPageZoom = .default
    private var overflows = false
    var onToggleMore: (() -> Void)?
    var onFold: (() -> Void)?
    private(set) var askID: AgentNodeID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textLabel.isSelectable = false
        textLabel.cell?.truncatesLastVisibleLine = true
        textLabel.lineBreakMode = .byWordWrapping
        for label in [timeLabel, moreLabel, foldLabel] {
            label.lineBreakMode = .byClipping
            label.alignment = .right
        }
        moreLabel.stringValue = "more"
        foldLabel.stringValue = "\u{2303}"
        [textLabel, timeLabel, moreLabel, foldLabel].forEach {
            $0.setAccessibilityElement(false)
            addSubview($0)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(id: AgentNodeID, model: AgentTurnAskModel, context: AgentRenderContext) {
        askID = id
        self.model = model
        zoom = context.pageZoom
        let theme = context.appearance
        textLabel.font = AgentTurnCardMetrics.askFont(zoom: zoom)
        textLabel.attributedStringValue = Self.attributed(model.text, zoom: zoom, theme: theme)
        textLabel.maximumNumberOfLines = model.isExpanded ? 0 : AgentTurnCardMetrics.askClampLines
        for label in [timeLabel, moreLabel, foldLabel] {
            label.font = AgentTurnCardMetrics.metaFont(zoom: zoom)
            label.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        }
        timeLabel.stringValue = model.timeText ?? ""
        timeLabel.isHidden = model.timeText == nil
        foldLabel.isHidden = !model.canFold
        moreLabel.stringValue = model.isExpanded ? "less" : "more"
        identifier = NSUserInterfaceItemIdentifier("agent.turnAsk.\(id.rawValue)")
        setAccessibilityLabel("You asked: \(model.text)")
        needsLayout = true
    }

    static func attributed(_ text: String, zoom: AgentPageZoom, theme: TokenTheme) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        let line = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.askLineHeight, zoom)
        style.minimumLineHeight = line
        style.maximumLineHeight = line
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: AgentTurnCardMetrics.askFont(zoom: zoom),
            .foregroundColor: TextToken.textPrimary.color.nsColor(for: theme),
            .paragraphStyle: style,
        ])
    }

    /// NSTextFieldCell's line-fragment padding: where a label's first glyph
    /// sits inside its frame.
    static let labelGlyphInset: CGFloat = 2

    /// The trailing column the time (and the fold chevron) occupy.
    static func accessoryWidth(timeText: String?, canFold: Bool, zoom: AgentPageZoom) -> CGFloat {
        let font = AgentTurnCardMetrics.metaFont(zoom: zoom)
        let time = (timeText ?? "") as NSString
        var width = ceil(time.size(withAttributes: [.font: font]).width)
        let more = ceil(("less" as NSString).size(withAttributes: [.font: font]).width)
        width = max(width, more)
        if canFold { width += AgentTurnCardMetrics.scaled(16, zoom) }
        return width + AgentTurnCardMetrics.scaled(12, zoom)
    }

    /// Height and whether the clamp hides anything. Pure and cheap; the list
    /// caches it per (turn, width, expansion, zoom), never in `layout()`.
    static func measure(_ model: AgentTurnAskModel, width: CGFloat, zoom: AgentPageZoom)
        -> (height: CGFloat, overflows: Bool) {
        let textWidth = max(1, width - accessoryWidth(timeText: model.timeText, canFold: model.canFold, zoom: zoom))
        let line = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.askLineHeight, zoom)
        let bounds = attributed(model.text, zoom: zoom, theme: .dark).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lines = max(1, Int((ceil(bounds.height) / line).rounded()))
        let shown = model.isExpanded ? lines : min(lines, AgentTurnCardMetrics.askClampLines)
        return (CGFloat(shown) * line, lines > AgentTurnCardMetrics.askClampLines)
    }

    override func layout() {
        super.layout()
        let accessory = Self.accessoryWidth(timeText: model.timeText, canFold: model.canFold, zoom: zoom)
        let textWidth = max(1, bounds.width - accessory)
        let measured = Self.measure(model, width: bounds.width, zoom: zoom)
        overflows = measured.overflows
        // A borderless label draws its glyphs one line-fragment padding inside
        // its frame; pull the frame out by that much so the Ask's first glyph
        // sits on the same edge as the answer's (an NSTextView with no inset).
        let glyphInset = Self.labelGlyphInset
        let textFrame = NSRect(x: -glyphInset, y: 0, width: textWidth + glyphInset * 2, height: bounds.height)
        if textLabel.frame != textFrame { textLabel.frame = textFrame }
        let metaHeight = ceil(timeLabel.intrinsicContentSize.height)
        let line = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.askLineHeight, zoom)
        let metaY = max(0, (line - metaHeight) / 2)
        let timeFrame = NSRect(x: bounds.width - accessory, y: metaY, width: accessory, height: metaHeight)
        if timeLabel.frame != timeFrame { timeLabel.frame = timeFrame }
        let chevron = AgentTurnCardMetrics.scaled(14, zoom)
        let timeWidth = ceil(timeLabel.intrinsicContentSize.width)
        let foldFrame = NSRect(
            x: bounds.width - (model.timeText == nil ? 0 : timeWidth + AgentTurnCardMetrics.scaled(4, zoom)) - chevron,
            y: metaY, width: chevron, height: metaHeight)
        if foldLabel.frame != foldFrame { foldLabel.frame = foldFrame }
        moreLabel.isHidden = !overflows
        let moreFrame = NSRect(
            x: bounds.width - accessory, y: max(0, bounds.height - line + metaY),
            width: accessory, height: metaHeight)
        if moreLabel.frame != moreFrame { moreLabel.frame = moreFrame }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return super.mouseUp(with: event) }
        if model.canFold, point.x >= bounds.width - Self.accessoryWidth(
            timeText: model.timeText, canFold: true, zoom: zoom), point.y < bounds.height / 2 + 1 {
            onFold?()
        } else if overflows {
            onToggleMore?()
        }
    }

    var qaOverflows: Bool { overflows }
}

// MARK: - Work strip

/// The turn's work as ONE line, live while the turn runs: glyph, what it is
/// doing, the clock, the activity barcode and the step count. Settled, it says
/// what the turn cost. Click opens the work log in place.
///
/// The fill and the barcode are drawn, not layered or sub-viewed: one view per
/// strip whatever the step count (`performance.md` trap 1), and nothing here is
/// a `TokenThemed` layer owner (CLAUDE.md hazard 8) — every colour is a token.
@MainActor
final class AgentWorkStripView: NSView {
    private(set) var glyphLabel = NSTextField(labelWithString: "")
    private(set) var textLabel = NSTextField(labelWithString: "")
    private(set) var countLabel = NSTextField(labelWithString: "")
    private(set) var model = AgentWorkStripModel(
        tone: .working, text: "", ticks: [], countText: nil, hasWork: false, isExpanded: false)
    private(set) var stripID: AgentNodeID?
    private var zoom: AgentPageZoom = .default
    private var theme: TokenTheme = .dark
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textLabel.lineBreakMode = .byTruncatingTail
        countLabel.alignment = .right
        [glyphLabel, textLabel, countLabel].forEach {
            $0.setAccessibilityElement(false)
            addSubview($0)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(id: AgentNodeID, model: AgentWorkStripModel, context: AgentRenderContext) {
        stripID = id
        zoom = context.pageZoom
        theme = context.appearance
        glyphLabel.font = AgentTurnCardMetrics.stripFont(zoom: zoom)
        textLabel.font = AgentTurnCardMetrics.stripFont(zoom: zoom)
        countLabel.font = AgentTurnCardMetrics.metaFont(zoom: zoom)
        textLabel.textColor = TextToken.textPrimary.color.nsColor(for: theme)
        countLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        identifier = NSUserInterfaceItemIdentifier("agent.workStrip.\(id.rawValue)")
        setModel(model)
    }

    /// Direct re-drive for the live tick: text and glyph only, no reload.
    func setModel(_ model: AgentWorkStripModel) {
        let geometryMoved = model.ticks.count != self.model.ticks.count
            || model.countText != self.model.countText || model.hasWork != self.model.hasWork
        let toneMoved = model.tone != self.model.tone
        self.model = model
        glyphLabel.stringValue = model.tone.glyph
        glyphLabel.textColor = model.tone.glyphColor(theme)
        if textLabel.stringValue != model.text { textLabel.stringValue = model.text }
        var trailing = model.countText ?? ""
        if model.hasWork { trailing += (trailing.isEmpty ? "" : " ") + (model.isExpanded ? "\u{2303}" : "\u{2304}") }
        countLabel.stringValue = trailing
        setAccessibilityLabel(
            model.text + (model.countText.map { ", \($0) steps" } ?? "")
                + (model.hasWork ? (model.isExpanded ? ", work log open" : ", work log closed") : ""))
        if geometryMoved { needsLayout = true }
        if geometryMoved || toneMoved { needsDisplay = true }
    }

    private var barcodeRect: NSRect = .zero

    override func layout() {
        super.layout()
        let padX = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.stripHorizontalPadding, zoom)
        let line = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.stripLineHeight, zoom)
        let top = (bounds.height - line) / 2
        let gap = AgentTurnCardMetrics.scaled(8, zoom)
        let glyphWidth = ceil(glyphLabel.intrinsicContentSize.width)
        let labelHeight = ceil(textLabel.intrinsicContentSize.height)
        let labelY = top + (line - labelHeight) / 2
        let glyphFrame = NSRect(x: padX, y: labelY, width: glyphWidth, height: labelHeight)
        if glyphLabel.frame != glyphFrame { glyphLabel.frame = glyphFrame }
        let countWidth = model.countText == nil && !model.hasWork ? 0 : ceil(countLabel.intrinsicContentSize.width)
        let countHeight = ceil(countLabel.intrinsicContentSize.height)
        let countFrame = NSRect(
            x: bounds.width - padX - countWidth, y: top + (line - countHeight) / 2,
            width: countWidth, height: countHeight)
        if countLabel.frame != countFrame { countLabel.frame = countFrame }
        let ticks = min(model.ticks.count, AgentTurnCardMetrics.maximumTicks)
        let tickW = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.tickWidth, zoom)
        let tickGap = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.tickGap, zoom)
        let tickH = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.tickHeight, zoom)
        let barcodeWidth = ticks == 0 ? 0 : CGFloat(ticks) * tickW + CGFloat(ticks - 1) * tickGap
        let barcodeMaxX = countFrame.minX - (countWidth > 0 ? gap : 0)
        let barcode = NSRect(
            x: barcodeMaxX - barcodeWidth, y: top + (line - tickH) / 2, width: barcodeWidth, height: tickH)
        if barcode != barcodeRect {
            barcodeRect = barcode
            needsDisplay = true
        }
        let textX = glyphFrame.maxX + gap
        let textMaxX = barcodeWidth > 0 ? barcodeRect.minX - gap : barcodeMaxX
        let textFrame = NSRect(x: textX, y: labelY, width: max(1, textMaxX - textX), height: labelHeight)
        if textLabel.frame != textFrame { textLabel.frame = textFrame }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = AgentTurnCardMetrics.scaled(CGFloat(CornerRole.artifact.radius), zoom)
        model.tone.fillColor(theme).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let ticks = model.ticks.suffix(AgentTurnCardMetrics.maximumTicks)
        guard !ticks.isEmpty, barcodeRect.width > 0 else { return }
        let tickW = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.tickWidth, zoom)
        let tickGap = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.tickGap, zoom)
        var x = barcodeRect.minX
        for tick in ticks {
            tick.color(theme).setFill()
            NSRect(x: x, y: barcodeRect.minY, width: tickW, height: barcodeRect.height).fill()
            x += tickW + tickGap
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), model.hasWork else { return super.mouseUp(with: event) }
        onToggle?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard model.hasWork else { return false }
        onToggle?()
        return true
    }

    var qaBarcodeRect: NSRect { barcodeRect }
}

// MARK: - Folded turn

/// An earlier turn as one object: what you asked, and what came of it.
@MainActor
final class AgentFoldedTurnView: NSView {
    private(set) var askLabel = NSTextField(labelWithString: "")
    private(set) var timeLabel = NSTextField(labelWithString: "")
    private(set) var glyphLabel = NSTextField(labelWithString: "")
    private(set) var outcomeLabel = NSTextField(labelWithString: "")
    private(set) var model = AgentFoldedTurnModel(askText: "", timeText: nil, tone: .done, outcomeText: "")
    private(set) var foldID: AgentNodeID?
    private var zoom: AgentPageZoom = .default
    var onOpen: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        askLabel.lineBreakMode = .byTruncatingTail
        outcomeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.alignment = .right
        [askLabel, timeLabel, glyphLabel, outcomeLabel].forEach {
            $0.setAccessibilityElement(false)
            addSubview($0)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(id: AgentNodeID, model: AgentFoldedTurnModel, context: AgentRenderContext) {
        foldID = id
        self.model = model
        zoom = context.pageZoom
        let theme = context.appearance
        askLabel.font = AgentTurnCardMetrics.foldedAskFont(zoom: zoom)
        askLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        askLabel.stringValue = model.askText
        timeLabel.font = AgentTurnCardMetrics.metaFont(zoom: zoom)
        timeLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        timeLabel.stringValue = model.timeText ?? ""
        timeLabel.isHidden = model.timeText == nil
        glyphLabel.font = AgentTurnCardMetrics.outcomeFont(zoom: zoom)
        glyphLabel.stringValue = model.tone.glyph
        glyphLabel.textColor = model.tone.glyphColor(theme)
        outcomeLabel.font = AgentTurnCardMetrics.outcomeFont(zoom: zoom)
        outcomeLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        outcomeLabel.alphaValue = Opacity.receded
        outcomeLabel.stringValue = model.outcomeText
        identifier = NSUserInterfaceItemIdentifier("agent.foldedTurn.\(id.rawValue)")
        setAccessibilityLabel("You asked: \(model.askText). \(model.outcomeText). Folded; press to open.")
        needsLayout = true
    }

    /// Re-drive for a duration or file count that arrived after the fold.
    func setOutcomeText(_ text: String) {
        guard outcomeLabel.stringValue != text else { return }
        model.outcomeText = text
        outcomeLabel.stringValue = text
    }

    override func layout() {
        super.layout()
        let pad = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.foldedVerticalPadding, zoom)
        let askLine = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.foldedAskLineHeight, zoom)
        let outcomeLine = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.foldedOutcomeLineHeight, zoom)
        let gap = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.foldedLineGap, zoom)
        let timeWidth = model.timeText == nil ? 0 : ceil(timeLabel.intrinsicContentSize.width)
        let inset = AgentTurnAskView.labelGlyphInset
        let askHeight = ceil(askLabel.intrinsicContentSize.height)
        let askFrame = NSRect(
            x: -inset, y: pad + (askLine - askHeight) / 2,
            width: max(1, bounds.width - timeWidth - (timeWidth > 0 ? AgentTurnCardMetrics.scaled(12, zoom) : 0)),
            height: askHeight)
        if askLabel.frame != askFrame { askLabel.frame = askFrame }
        let timeHeight = ceil(timeLabel.intrinsicContentSize.height)
        let timeFrame = NSRect(
            x: bounds.width - timeWidth, y: pad + (askLine - timeHeight) / 2, width: timeWidth, height: timeHeight)
        if timeLabel.frame != timeFrame { timeLabel.frame = timeFrame }
        let outcomeY = pad + askLine + gap
        let glyphWidth = ceil(glyphLabel.intrinsicContentSize.width)
        let outcomeHeight = ceil(outcomeLabel.intrinsicContentSize.height)
        let glyphFrame = NSRect(
            x: -inset, y: outcomeY + (outcomeLine - outcomeHeight) / 2, width: glyphWidth, height: outcomeHeight)
        if glyphLabel.frame != glyphFrame { glyphLabel.frame = glyphFrame }
        let textX = glyphFrame.maxX + AgentTurnCardMetrics.scaled(4, zoom)
        let outcomeFrame = NSRect(
            x: textX, y: glyphFrame.minY, width: max(1, bounds.width - textX), height: outcomeHeight)
        if outcomeLabel.frame != outcomeFrame { outcomeLabel.frame = outcomeFrame }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return super.mouseUp(with: event) }
        onOpen?()
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
}

// MARK: - Outcome

/// What the turn changed, as chips that open the change: `≡ Name.swift +18 −4`.
/// Drawn, one view per turn however many files (`performance.md` trap 1).
@MainActor
final class AgentTurnOutcomeView: NSView {
    private(set) var model = AgentTurnOutcomeModel(chips: [])
    private(set) var outcomeID: AgentNodeID?
    private var zoom: AgentPageZoom = .default
    private var theme: TokenTheme = .dark
    private var chipFrames: [NSRect] = []
    var onOpenChip: ((AgentTurnOutcomeModel.Chip) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Changed files")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(id: AgentNodeID, model: AgentTurnOutcomeModel, context: AgentRenderContext) {
        outcomeID = id
        self.model = model
        zoom = context.pageZoom
        theme = context.appearance
        identifier = NSUserInterfaceItemIdentifier("agent.turnOutcome.\(id.rawValue)")
        needsLayout = true
        needsDisplay = true
    }

    static func chipText(_ chip: AgentTurnOutcomeModel.Chip, theme: TokenTheme, zoom: AgentPageZoom)
        -> NSAttributedString {
        let font = AgentTurnCardMetrics.chipFont(zoom: zoom)
        let text = NSMutableAttributedString(string: "\u{2261} \(chip.title)", attributes: [
            .font: font, .foregroundColor: TextToken.textPrimary.color.nsColor(for: theme),
        ])
        if let added = chip.added {
            text.append(NSAttributedString(string: "  +\(added)", attributes: [
                .font: font, .foregroundColor: AccentToken.accentDone.color.nsColor(for: theme),
            ]))
        }
        if let removed = chip.removed {
            text.append(NSAttributedString(string: " \u{2212}\(removed)", attributes: [
                .font: font, .foregroundColor: AccentToken.accentFailed.color.nsColor(for: theme),
            ]))
        }
        return text
    }

    /// Chip frames for a width, wrapping onto further lines. Pure; the list
    /// measures with it and this view lays out with it, so the two agree.
    static func chipFrames(for model: AgentTurnOutcomeModel, width: CGFloat, zoom: AgentPageZoom) -> [NSRect] {
        let height = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.chipHeight, zoom)
        let gap = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.chipGap, zoom)
        let pad = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.chipHorizontalPadding, zoom)
        var frames: [NSRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        for chip in model.chips {
            let textWidth = ceil(chipText(chip, theme: .dark, zoom: zoom).size().width)
            let chipWidth = min(width, textWidth + pad * 2)
            if x > 0, x + chipWidth > width {
                x = 0
                y += height + gap
            }
            frames.append(NSRect(x: x, y: y, width: chipWidth, height: height))
            x += chipWidth + gap
        }
        return frames
    }

    static func measuredHeight(for model: AgentTurnOutcomeModel, width: CGFloat, zoom: AgentPageZoom) -> CGFloat {
        chipFrames(for: model, width: width, zoom: zoom).last?.maxY ?? 0
    }

    override func layout() {
        super.layout()
        let frames = Self.chipFrames(for: model, width: bounds.width, zoom: zoom)
        if frames != chipFrames {
            chipFrames = frames
            needsDisplay = true
            rebuildAccessibility()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = AgentTurnCardMetrics.scaled(CGFloat(CornerRole.card.radius), zoom)
        let pad = AgentTurnCardMetrics.scaled(AgentTurnCardMetrics.chipHorizontalPadding, zoom)
        for (chip, frame) in zip(model.chips, chipFrames) where frame.intersects(dirtyRect) {
            AgentSurfaceRole.artifact.color.nsColor(for: theme).setFill()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
            let text = Self.chipText(chip, theme: theme, zoom: zoom)
            let size = text.size()
            text.draw(
                with: NSRect(x: frame.minX + pad, y: frame.midY - size.height / 2,
                             width: frame.width - pad * 2, height: size.height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func rebuildAccessibility() {
        let elements = zip(model.chips, chipFrames).map { chip, frame -> NSAccessibilityElement in
            let element = AgentTurnOutcomeChipElement(chip: chip) { [weak self] in self?.onOpenChip?(chip) }
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(frame)
            return element
        }
        setAccessibilityChildren(elements)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = chipFrames.firstIndex(where: { $0.contains(point) }),
              model.chips.indices.contains(index) else { return super.mouseUp(with: event) }
        onOpenChip?(model.chips[index])
    }

    var qaChipFrames: [NSRect] { chipFrames }
}

@MainActor
private final class AgentTurnOutcomeChipElement: NSAccessibilityElement {
    private let press: () -> Void

    init(chip: AgentTurnOutcomeModel.Chip, press: @escaping () -> Void) {
        self.press = press
        super.init()
        setAccessibilityRole(.button)
        var label = "Open changes to \(chip.title)"
        if let added = chip.added { label += ", \(added) added" }
        if let removed = chip.removed { label += ", \(removed) removed" }
        setAccessibilityLabel(label)
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}
