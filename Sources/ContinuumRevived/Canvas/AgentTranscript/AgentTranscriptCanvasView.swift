import AppKit
import CoreText
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// The agent transcript as ONE layer-backed view with no subviews, drawn with
/// CoreText.
///
/// Why it exists: `AgentTranscriptListView` is hundreds of AppKit views per tile
/// (collection view, cells, text views, buttons, Auto Layout), and AppKit lays out
/// and redraws every one of them on every canvas zoom step. Measured on Dylan's
/// replayed canvas, Array's own code is ~2% of a zoom frame and the view tree is
/// the rest; with one view per tile the camera reached 60-101 updates/s.
///
/// Dylan's rules for any replacement: full detail always, no pictures or
/// low-resolution stand-ins, and no visible change between moving and still. So
/// this is the ONLY renderer, at rest and in motion: every block is laid out once
/// at the view's width (`LaidBlock`, cached by identity + revision + width +
/// context + presentation), and `draw(_:)` strokes the cached `CTLine`s,
/// decorations and drawn controls that intersect the dirty rect at whatever scale
/// AppKit hands it. A canvas zoom raises the layer's `contentsScale` and the same
/// lines are drawn again, sharp, with no layout.
///
/// Controls (request choices, disclosure chevrons, Copy, Open Review, chips) are
/// drawn rects with hover/pressed state that dispatch the same `AgentRenderAction`s
/// the row renderers do. The only thing this view owns besides its own drawing is
/// one small CALayer for the animated thinking gyro.
///
/// The default renderer since 0.7.32. `ARRAY_TRANSCRIPT_RENDERER=list` or the
/// user default `continuum.transcript.renderer = list` selects the row list
/// instead, read once per tile.
/// Witness: `--transcript-canvas-check` (`TranscriptCanvasChecks`).
@MainActor
final class AgentTranscriptCanvasView: NSView, AgentTranscriptSurface, NSMenuItemValidation {
    // MARK: Switch

    static let rendererEnvironmentKey = "ARRAY_TRANSCRIPT_RENDERER"
    static let rendererDefaultsKey = "continuum.transcript.renderer"

    /// Read by the tile once, at construction.
    static var isSelected: Bool {
        if let value = ProcessInfo.processInfo.environment[rendererEnvironmentKey] { return value != "list" }
        return UserDefaults.standard.string(forKey: rendererDefaultsKey) != "list"
    }

    enum UpdateError: Error, Equatable {
        case documentPatchMismatch(document: UInt64, patch: UInt64)
        case versionMismatch(expected: UInt64, actual: UInt64)
    }

    // MARK: Layout model

    /// One laid-out line of selectable text. Every coordinate is block-local.
    struct Line {
        let ctLine: CTLine
        /// In the owning row's string.
        let range: NSRange
        var x: CGFloat
        var top: CGFloat
        let height: CGFloat
        var baseline: CGFloat
        let width: CGFloat
        var fills: [(CGRect, CGColor)]
        var underlines: [(CGRect, CGColor)]

        func shifted(dx: CGFloat, dy: CGFloat) -> Line {
            var copy = self
            copy.x += dx
            copy.top += dy
            copy.baseline += dy
            copy.fills = fills.map { ($0.0.offsetBy(dx: dx, dy: dy), $0.1) }
            copy.underlines = underlines.map { ($0.0.offsetBy(dx: dx, dy: dy), $0.1) }
            return copy
        }
    }

    /// One selectable run of text: a prose row, a code block, a tool title.
    struct TextRow {
        let string: NSAttributedString
        var lines: [Line]
        let links: [AgentTextStyleResolver.LinkRange]
        /// The block's scroll region this row lives in (code, tool output).
        var region: Int? = nil
        /// The block that owns this row's links, when it is not the unit itself
        /// (a block inside a reasoning disclosure).
        var ownerID: AgentNodeID? = nil
    }

    enum Decoration {
        case fill(CGRect, CGColor, radius: CGFloat)
        case stroke(CGRect, CGColor, radius: CGFloat, width: CGFloat)
        /// Non-selectable text (markers, labels, status), drawn at a baseline.
        case text(CTLine, CGPoint)
        case symbol(NSImage, CGRect)
        /// An attachment drawn from its full-resolution source, or its state
        /// label until that source arrives.
        case image(AgentImageAttachmentID, CGRect, placeholder: CTLine?)

        func shifted(dx: CGFloat, dy: CGFloat) -> Decoration {
            switch self {
            case let .fill(rect, color, radius): return .fill(rect.offsetBy(dx: dx, dy: dy), color, radius: radius)
            case let .stroke(rect, color, radius, width):
                return .stroke(rect.offsetBy(dx: dx, dy: dy), color, radius: radius, width: width)
            case let .text(line, point): return .text(line, CGPoint(x: point.x + dx, y: point.y + dy))
            case let .symbol(image, rect): return .symbol(image, rect.offsetBy(dx: dx, dy: dy))
            case let .image(id, rect, placeholder): return .image(id, rect.offsetBy(dx: dx, dy: dy), placeholder: placeholder)
            }
        }
    }

    /// A clipped, independently scrolled part of a block: a code body or a tool's
    /// output pane. Rows assigned to it draw translated by its offset.
    struct ScrollRegion {
        var viewport: CGRect
        var contentSize: CGSize
    }

    enum ControlAction {
        case perform(AgentRenderAction)
        case toggle(AgentNodeID, expanded: Bool)
        /// Writes `text` to the copy pasteboard, then reports `.copy(blockID:)`.
        case copy(String, AgentNodeID)
    }

    enum ControlStyle {
        /// A filled choice (request answers, error recovery): `AgentRequestChoiceButton`.
        case choice
        /// Borderless text: Copy, Open Review.
        case text
        /// The disclosure chevron: ▾ expanded, ▸ collapsed.
        case chevron(expanded: Bool)
        /// An invisible hit area over drawn content (a chip, an image, a sender);
        /// hover paints `hoverFill` when one is given.
        case region(hoverFill: CGColor?, pressedFill: CGColor?, radius: CGFloat)
    }

    struct Control {
        var rect: CGRect
        var title: String = ""
        var style: ControlStyle
        var action: ControlAction
        var enabled = true
        var font: NSFont? = nil
        var tint: NSColor? = nil

        func shifted(dx: CGFloat, dy: CGFloat) -> Control {
            var copy = self
            copy.rect = rect.offsetBy(dx: dx, dy: dy)
            return copy
        }
    }

    /// Everything one unit draws, assembled before it is frozen into a `LaidBlock`.
    struct Builder {
        var rows: [TextRow] = []
        var decorations: [Decoration] = []
        var controls: [Control] = []
        var regions: [ScrollRegion] = []
        var images: [AgentImageMenuTarget] = []
        var containedIDs: Set<AgentNodeID> = []

        /// Places a laid child at (dx, dy): a block inside a reasoning disclosure.
        mutating func embed(_ child: LaidBlock, dx: CGFloat, dy: CGFloat) {
            let regionBase = regions.count
            regions += child.regions.map {
                ScrollRegion(viewport: $0.viewport.offsetBy(dx: dx, dy: dy), contentSize: $0.contentSize)
            }
            for row in child.rows {
                var moved = row
                moved.lines = row.lines.map { $0.shifted(dx: dx, dy: dy) }
                moved.region = row.region.map { $0 + regionBase }
                moved.ownerID = row.ownerID ?? child.id
                rows.append(moved)
            }
            decorations += child.decorations.map { $0.shifted(dx: dx, dy: dy) }
            controls += child.controls.map { $0.shifted(dx: dx, dy: dy) }
            images += child.images.map { AgentImageMenuTarget(rect: $0.rect.offsetBy(dx: dx, dy: dy), blockID: $0.blockID, attachmentID: $0.attachmentID, snapshot: $0.snapshot) }
            containedIDs.insert(child.id)
            containedIDs.formUnion(child.containedIDs)
        }
    }

    /// An image hit area, for the click and the context menu.
    struct AgentImageMenuTarget {
        let rect: CGRect
        let blockID: AgentNodeID
        let attachmentID: AgentImageAttachmentID
        let snapshot: AgentImageResourceSnapshot
    }

    final class LaidBlock {
        let id: AgentNodeID
        let revision: UInt64
        let width: CGFloat
        let contextSignature: Int
        let role: AgentEntryRole
        /// Everything outside the semantic revision that changes this layout:
        /// disclosure state, live statuses, image snapshots, reasoning duration.
        let variant: Int
        /// The presented copy of a tool/diff block (host-local detail merged in);
        /// compared because detail arrives without a revision.
        let presented: AgentBlockPayload?
        let height: CGFloat
        let rows: [TextRow]
        let decorations: [Decoration]
        let controls: [Control]
        let regions: [ScrollRegion]
        let images: [AgentImageMenuTarget]
        let containedIDs: Set<AgentNodeID>
        let alpha: CGFloat
        let clipsToBounds: Bool
        /// Each row's offset in the block's text; every row is followed by one
        /// separator, which copy renders as a newline.
        let rowOffsets: [Int]
        let textLength: Int

        init(id: AgentNodeID, revision: UInt64, width: CGFloat, contextSignature: Int, role: AgentEntryRole,
             variant: Int = 0, presented: AgentBlockPayload? = nil,
             height: CGFloat, builder: Builder, alpha: CGFloat = 1, clipsToBounds: Bool = false) {
            self.id = id
            self.revision = revision
            self.width = width
            self.contextSignature = contextSignature
            self.role = role
            self.variant = variant
            self.presented = presented
            self.height = height
            self.rows = builder.rows
            self.decorations = builder.decorations
            self.controls = builder.controls
            self.regions = builder.regions
            self.images = builder.images
            self.containedIDs = builder.containedIDs
            self.alpha = alpha
            self.clipsToBounds = clipsToBounds
            var offsets: [Int] = []
            var cursor = 0
            for row in builder.rows {
                offsets.append(cursor)
                cursor += row.string.length + 1
            }
            rowOffsets = offsets
            textLength = cursor
        }
    }

    /// A laid block at its document position.
    struct Placed {
        let block: LaidBlock
        let y: CGFloat
        let textStart: Int
        let blockID: AgentNodeID
    }

    struct ControlKey: Hashable {
        let blockID: AgentNodeID
        let index: Int
    }

    struct RegionKey: Hashable {
        let blockID: AgentNodeID
        let index: Int
    }

    // MARK: State

    let toolDetail: AgentTranscriptCanvasToolDetail
    /// The tile's context with this transcript's own disclosure store wired in,
    /// exactly as `AgentTranscriptListView.contextWithDisclosureState` does.
    var renderContext = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private let disclosureStateStore = DisclosureStateStore()
    private let disclosureOwnerID = AgentID(rawValue: UUID())
    private let toolClockScope = AgentToolClockScope()
    private let updateScheduler = AgentTranscriptUpdateScheduler()
    private var latestEnqueuedVersion: UInt64?
    private var appliedVersion: UInt64?
    private var document = AgentDocument()
    private var renderingError: Error?

    private var cache: [AgentNodeID: LaidBlock] = [:]
    private var placed: [Placed] = []
    private var contentHeight: CGFloat = 0
    private var blocksBottom: CGFloat = 0
    private var laidWidth: CGFloat = -1
    private var scrollOffset: CGFloat = 0
    private let nearBottomThreshold = AgentTranscriptScrollController().nearBottomThreshold

    private var tailVisible = false
    private var tailSettled = false
    private var tailText = ""
    private var tailLine: (line: CTLine, top: CGFloat, baseline: CGFloat, x: CGFloat)?
    private var turnInFlight = false
    private let gyro = AgentTranscriptCanvasGyroLayer()

    /// Selection in document text offsets: `anchor` is where the press began.
    private var selectionAnchor: Int?
    private var selectionFocus: Int?
    private var mouseDownIndex: Int?
    private var mouseDragged = false
    private var scrollIndicatorVisibleUntil: Date = .distantPast
    private var scrollIndicatorTimer: Timer?

    private var hoveredControl: ControlKey?
    private var pressedControl: ControlKey?
    private var pressedInside = false
    private var focusedControl: ControlKey?
    private var trackingArea: NSTrackingArea?
    private var regionOffsets: [RegionKey: CGPoint] = [:]

    /// Full-resolution image sources by attachment, drawn at whatever scale the
    /// layer is shown. Never a downscaled copy.
    var imageSources: [AgentImageAttachmentID: (revision: UInt64, image: NSImage)] = [:]
    var imageRequests: [AgentImageAttachmentID: AgentImageThumbnailRequest] = [:]
    var imageObservations: [AgentImageAttachmentID: AgentImageResourceObservation] = [:]
    var statusSubscriptions: [UUID: UUID] = [:]

    /// The pasteboard Cmd-C and drawn Copy buttons write. Checks substitute a
    /// private one so a witness never touches the user's clipboard.
    var pasteboardForCopy: NSPasteboard = .general

    // MARK: QA counters

    private(set) var qaBlockLayoutCount = 0
    private(set) var qaLastRelaidBlockIDs: [AgentNodeID] = []
    private(set) var qaFullRelayoutCount = 0
    private(set) var qaDrawCount = 0
    private(set) var qaLastDrawScale: CGFloat = 0
    private(set) var qaLastDrawnLineCount = 0
    private(set) var qaLastDrawnControlCount = 0
    var qaRenderingErrorDescription: String? { renderingError.map(String.init(describing:)) }
    var qaScrollOffset: CGFloat { scrollOffset }
    var qaMaximumScrollOffset: CGFloat { maximumScrollOffset }
    var qaContentHeight: CGFloat { contentHeight }
    var qaPlacedBlockIDs: [AgentNodeID] { placed.map(\.blockID) }
    var qaGyroIsAnimating: Bool { gyro.isAnimating }
    var qaGyroLayer: CALayer { gyro }

    // MARK: Init

    init(toolDetailStore: AgentToolDetailStore? = nil) {
        toolDetail = AgentTranscriptCanvasToolDetail(store: toolDetailStore)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.addSublayer(gyro)
        gyro.isHidden = true
        updateScheduler.isPresentable = { [weak self] in self?.isOnScreenForVisualUpdates ?? true }
        toolDetail.onRefresh = { [weak self] in
            guard let self else { return }
            self.preservingTail { self.rebuild() }
        }
        renderContext = contextWithDisclosureState(renderContext)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent transcript")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    var isOnScreenForVisualUpdates: Bool {
        guard window != nil else { return true }
        return !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { updateScheduler.flush() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileGyro()
    }

    override func viewDidHide() {
        super.viewDidHide()
        reconcileGyro()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reconcileGyro()
    }

    private func contextWithDisclosureState(_ context: AgentRenderContext) -> AgentRenderContext {
        var context = context
        context.toolClockScope = toolClockScope
        context.actions = disclosureStateStore.renderActions(
            for: disclosureOwnerID,
            perform: context.actions.perform,
            invalidatePresentation: { [weak self] id in self?.invalidatePresentation(of: id) }
        )
        return context
    }

    /// A disclosure toggled or a live source moved: re-lay out that unit only and
    /// keep what the reader was looking at where it was.
    func invalidatePresentation(of id: AgentNodeID) {
        cache.removeValue(forKey: id)
        for (key, block) in cache where block.containedIDs.contains(id) { cache.removeValue(forKey: key) }
        rebuild()
        scrollOffset = min(scrollOffset, maximumScrollOffset)
        needsDisplay = true
    }

    // MARK: AgentTranscriptSurface

    func enqueue(document: AgentDocument, patch: AgentDocumentPatch, final: Bool = false) throws {
        guard document.version == patch.toVersion else {
            throw UpdateError.documentPatchMismatch(document: document.version, patch: patch.toVersion)
        }
        let expected = latestEnqueuedVersion ?? appliedVersion ?? patch.fromVersion
        guard patch.fromVersion == expected else {
            throw UpdateError.versionMismatch(expected: expected, actual: patch.fromVersion)
        }
        latestEnqueuedVersion = patch.toVersion
        updateScheduler.schedule({ [weak self] in
            guard let self else { return }
            self.document = document
            self.appliedVersion = document.version
            self.preservingTail { self.rebuild() }
        }, final: final)
    }

    func flushPendingVisualUpdate() { updateScheduler.flush() }

    func jumpToLatest() {
        scrollOffset = maximumScrollOffset
        positionGyro()
        needsDisplay = true
    }

    func updateRenderContext(_ context: AgentRenderContext) throws {
        let moved = Self.signature(of: context) != Self.signature(of: renderContext)
            || context.tokens != renderContext.tokens
        renderContext = contextWithDisclosureState(context)
        gyro.apply(theme: context.appearance)
        guard moved else { return }
        cache.removeAll()
        preservingTail { rebuild() }
    }

    func bindToolDetailAgent(_ agentID: AgentID?) {
        toolDetail.bind(agentID: agentID)
        if let agentID {
            gyro.phaseOffset = DualPlaneGyroTiltedThinkingIndicatorView.phaseOffset(for: agentID.rawValue)
        }
    }

    func captureRuntimeObservation(_ observation: AgentRuntimeObservation) {
        toolDetail.captureRuntimeObservation(observation)
    }

    @discardableResult
    func captureRuntimeEvent(_ event: AgentRuntimeEvent) -> AgentToolDetailKey? {
        toolDetail.captureRuntimeEvent(event)
    }

    func bindToolDetailIdentity(_ identity: AgentToolDetailKey, to entryID: AgentNodeID) -> Bool {
        toolDetail.bindIdentity(identity, to: entryID)
    }

    func setThinkingIndicatorVisible(_ visible: Bool) {
        let changed = tailVisible != visible || tailSettled
        tailSettled = false
        tailVisible = visible
        if !visible { tailText = "" }
        if changed { preservingTail { placeTail() } }
        reconcileGyro()
    }

    func setTurnInFlight(_ inFlight: Bool) { turnInFlight = inFlight }

    func setThinkingStatusText(_ text: String?) {
        let resolved = text ?? ""
        guard resolved != tailText else { return }
        tailText = resolved
        if tailVisible { placeTail(); needsDisplay = true }
    }

    func setTurnPresence(_ presence: AgentTurnPresence?) {}

    func setSettledTailStatus(_ text: String) {
        tailSettled = true
        tailText = text
        if !tailVisible {
            tailVisible = true
            preservingTail { placeTail() }
        } else {
            placeTail()
            needsDisplay = true
        }
        reconcileGyro()
    }

    var qaTailStatusText: String { tailText }

    var transcriptScrollOrigin: CGPoint { CGPoint(x: 0, y: scrollOffset) }

    func scrollTranscript(toY y: CGFloat) {
        scrollOffset = min(max(0, y), maximumScrollOffset)
        positionGyro()
        needsDisplay = true
    }

    // MARK: Geometry

    var insets: NSEdgeInsets {
        let value = CGFloat(renderContext.pageZoom.scaled(12))
        return NSEdgeInsets(top: value, left: value, bottom: value, right: value)
    }

    private var columnWidth: CGFloat { max(1, bounds.width - insets.left - insets.right) }

    private var maximumScrollOffset: CGFloat { max(0, contentHeight - bounds.height) }

    private var isNearBottom: Bool { maximumScrollOffset - scrollOffset <= nearBottomThreshold }

    /// Runs a geometry change; a reader at the bottom stays at the bottom, anyone
    /// else keeps their offset (clamped).
    func preservingTail(_ change: () -> Void) {
        let stick = isNearBottom
        change()
        scrollOffset = stick ? maximumScrollOffset : min(scrollOffset, maximumScrollOffset)
        positionGyro()
        needsDisplay = true
    }

    /// The same 2pt band `AssistantProseView` uses: pixel snapping during a camera
    /// zoom re-rounds widths by about a device pixel, and that must not re-shape
    /// every line. Lines are drawn at the width they were laid out at.
    static let widthHysteresis: CGFloat = 2

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        let stick = isNearBottom
        super.setFrameSize(newSize)
        if abs(newSize.width - oldSize.width) > 0.01 { needsLayout = true }
        if newSize.height != oldSize.height {
            scrollOffset = stick ? maximumScrollOffset : min(scrollOffset, maximumScrollOffset)
            positionGyro()
            needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        if laidWidth < 0 || abs(columnWidth - laidWidth) > Self.widthHysteresis {
            preservingTail { rebuild() }
        }
    }

    // MARK: Build

    static func signature(of context: AgentRenderContext) -> Int {
        var hasher = Hasher()
        hasher.combine(context.appearance.rawValue)
        hasher.combine(context.pageZoom.percent)
        hasher.combine(context.canRespondToRequests)
        return hasher.finalize()
    }

    /// One thing the transcript draws: a block, or a finished reasoning entry.
    enum Unit {
        case block(AgentBlock, AgentEntry)
        case reasoning(AgentEntry, duration: TimeInterval?)

        var id: AgentNodeID {
            switch self {
            case let .block(block, _): return block.id
            case let .reasoning(entry, _): return entry.id
            }
        }
    }

    /// Walk the document; lay out only units the cache cannot answer; place all.
    /// Never called from `draw`.
    func rebuild() {
        guard bounds.width > 0 else { return }
        let width = (laidWidth > 0 && abs(columnWidth - laidWidth) <= Self.widthHysteresis) ? laidWidth : columnWidth
        if width != laidWidth { qaFullRelayoutCount += 1 }
        laidWidth = width
        let signature = Self.signature(of: renderContext)
        let zoom = renderContext.pageZoom
        let rowSpacing = CGFloat(zoom.scaled(8))
        let turnSpacing = CGFloat(zoom.scaled(Double(AgentTranscriptLayout.interTurnSpacing)))

        var next: [AgentNodeID: LaidBlock] = [:]
        var relaid: [AgentNodeID] = []
        var result: [Placed] = []
        var y = insets.top
        var text = 0
        var previousEntryID: AgentNodeID?
        let entries = document.entries
        for (entryIndex, entry) in entries.enumerated() {
            var units: [Unit] = []
            if entry.role == .reasoning {
                // Open reasoning is shown by the tail status, as in the list.
                guard entry.lifecycle == .finished, !entry.blocks.isEmpty else { continue }
                units = [.reasoning(entry, duration: Self.reasoningDuration(entries, at: entryIndex))]
            } else {
                units = entry.blocks.map { .block($0, entry) }
            }
            for unit in units {
                let (revision, presented, variant) = identity(of: unit)
                let laid: LaidBlock
                if let cached = cache[unit.id], cached.revision == revision, cached.width == width,
                   cached.contextSignature == signature, cached.role == entry.role,
                   cached.variant == variant, cached.presented == presented {
                    laid = cached
                } else {
                    laid = layoutUnit(unit, width: width, signature: signature, variant: variant)
                    relaid.append(unit.id)
                }
                next[unit.id] = laid
                if !result.isEmpty {
                    // A user prompt after anything else opens a turn (the list's
                    // `startsTurn`): the wider gap.
                    let startsTurn = entry.role == .user && previousEntryID != entry.id
                    y += startsTurn ? turnSpacing : rowSpacing
                }
                result.append(Placed(block: laid, y: y, textStart: text, blockID: unit.id))
                y += laid.height
                text += laid.textLength
                previousEntryID = entry.id
            }
        }
        cache = next
        placed = result
        blocksBottom = y
        qaBlockLayoutCount += relaid.count
        qaLastRelaidBlockIDs = relaid
        placeTail()
        if let anchor = selectionAnchor, anchor > text { selectionAnchor = nil; selectionFocus = nil }
        let liveBlocks = Set(next.keys)
        regionOffsets = regionOffsets.filter { liveBlocks.contains($0.key.blockID) }
    }

    /// The parts of a unit's identity the cache compares.
    private func identity(of unit: Unit) -> (revision: UInt64, presented: AgentBlockPayload?, variant: Int) {
        var hasher = Hasher()
        hasher.combine(renderContext.actions.presentationRevision(blockID: unit.id))
        switch unit {
        case let .reasoning(entry, duration):
            hasher.combine(duration.map { Int($0) } ?? -1)
            for block in entry.blocks { hasher.combine(renderContext.actions.presentationRevision(blockID: block.id)) }
            return (entry.revision, nil, hasher.finalize())
        case let .block(block, entry):
            let presented = toolDetail.presented(block, in: entry)
            combineLiveVariant(of: presented, into: &hasher)
            switch presented.payload {
            case .toolCall, .diff: return (block.revision, presented.payload, hasher.finalize())
            default: return (block.revision, nil, hasher.finalize())
            }
        }
    }

    /// The list's `reasoningDuration`: the next dated entry's start minus this
    /// one's, when at least a second.
    private static func reasoningDuration(_ entries: [AgentEntry], at index: Int) -> TimeInterval? {
        guard let start = entries[index].createdAt else { return nil }
        guard let next = entries[(index + 1)...].lazy.compactMap(\.createdAt).first else { return nil }
        let duration = next.timeIntervalSince(start)
        return duration >= 1 ? duration : nil
    }

    private func placeTail() {
        let zoom = renderContext.pageZoom
        var y = blocksBottom
        if tailVisible {
            let side = DualPlaneGyroIndicatorModel.side
            if !placed.isEmpty { y += CGFloat(zoom.scaled(8)) }
            let font = NSFont.token(.caption, zoom: zoom)
            let color = renderContext.tokens.secondaryText.color.nsColor(for: renderContext.appearance)
            let line = CTLineCreateWithAttributedString(Self.coreTextString(
                NSAttributedString(string: tailText, attributes: [.font: font, .foregroundColor: color])))
            let baseline = y + (side - (font.ascender - font.descender)) / 2 + font.ascender
            tailLine = (line, y, baseline, insets.left + side + CGFloat(zoom.scaled(Space.s)))
            y += side
        } else {
            tailLine = nil
        }
        contentHeight = y + insets.bottom
        positionGyro()
    }

    // MARK: Gyro

    /// The tail's working gyro: animated only while a turn is working, the view is
    /// in a window and not hidden. A settled tail keeps its words, not the gyro.
    private func reconcileGyro() {
        let animate = tailVisible && !tailSettled && window != nil && !isHiddenOrHasHiddenAncestor
        gyro.isHidden = !animate
        if animate { gyro.start() } else { gyro.stop() }
        positionGyro()
    }

    private func positionGyro() {
        guard let tail = tailLine, !gyro.isHidden else { return }
        let side = DualPlaneGyroIndicatorModel.side
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gyro.frame = CGRect(x: insets.left, y: tail.top - scrollOffset, width: side, height: side)
        CATransaction.commit()
    }

    // MARK: Drawing

    var theme: TokenTheme { renderContext.appearance }
    func color(_ token: TextToken) -> NSColor { token.color.nsColor(for: theme) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        qaDrawCount += 1
        // The device transform carries the layer's contentsScale (the CTM does
        // not, under Core Animation's drawing contexts).
        let device = context.userSpaceToDeviceSpaceTransform
        qaLastDrawScale = hypot(device.a, device.b)
        gyro.matchContentsScale(qaLastDrawScale)
        let x0 = insets.left
        let visible = dirtyRect.offsetBy(dx: 0, dy: scrollOffset)
        let selection = selectedRange
        let highlight = NSColor.selectedTextBackgroundColor.cgColor
        var drawnLines = 0
        var drawnControls = 0
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        var index = firstPlaced(atOrBelow: visible.minY)
        while index < placed.count {
            let item = placed[index]
            index += 1
            if item.y > visible.maxY { break }
            let block = item.block
            guard item.y + block.height >= visible.minY else { continue }
            context.saveGState()
            context.translateBy(x: x0, y: item.y - scrollOffset)
            if block.alpha < 1 { context.setAlpha(block.alpha) }
            let localVisible = visible.offsetBy(dx: -x0, dy: -item.y)
            for decoration in block.decorations {
                switch decoration {
                case let .fill(rect, color, radius) where rect.intersects(localVisible):
                    context.setFillColor(color)
                    if radius > 0 {
                        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                        context.fillPath()
                    } else {
                        context.fill(rect)
                    }
                case let .stroke(rect, color, radius, width) where rect.intersects(localVisible):
                    context.setStrokeColor(color)
                    context.setLineWidth(width)
                    let inset = rect.insetBy(dx: width / 2, dy: width / 2)
                    context.addPath(CGPath(roundedRect: inset, cornerWidth: max(0, radius - width / 2),
                                           cornerHeight: max(0, radius - width / 2), transform: nil))
                    context.strokePath()
                default:
                    continue
                }
            }
            for (controlIndex, control) in block.controls.enumerated() where control.rect.intersects(localVisible) {
                drawControlBackground(control, key: ControlKey(blockID: item.blockID, index: controlIndex), in: context)
            }
            if block.clipsToBounds { context.clip(to: CGRect(x: 0, y: 0, width: block.width, height: block.height)) }
            for (rowIndex, row) in block.rows.enumerated() {
                let rowStart = item.textStart + block.rowOffsets[rowIndex]
                var offset = CGPoint.zero
                if let region = row.region, block.regions.indices.contains(region) {
                    offset = regionOffsets[RegionKey(blockID: item.blockID, index: region)] ?? .zero
                    context.saveGState()
                    context.clip(to: block.regions[region].viewport)
                    context.translateBy(x: -offset.x, y: -offset.y)
                }
                let rowVisible = localVisible.offsetBy(dx: offset.x, dy: offset.y)
                for line in row.lines {
                    guard line.top + line.height >= rowVisible.minY, line.top <= rowVisible.maxY else { continue }
                    if let selection {
                        let lineStart = rowStart + line.range.location
                        let lineEnd = lineStart + line.range.length
                        let lo = max(selection.location, lineStart)
                        let hi = min(NSMaxRange(selection), lineEnd)
                        // A selection running past this line paints to its end,
                        // the way a text view shows the line break as selected.
                        let continues = NSMaxRange(selection) > lineEnd && selection.location <= lineEnd
                        if lo < hi || (continues && selection.location < lineStart) {
                            let a = CTLineGetOffsetForStringIndex(line.ctLine, lo - rowStart, nil)
                            let b = continues ? line.width + 4 : CTLineGetOffsetForStringIndex(line.ctLine, hi - rowStart, nil)
                            context.setFillColor(highlight)
                            context.fill(CGRect(x: line.x + a, y: line.top, width: max(0, b - a), height: line.height))
                        }
                    }
                    for (rect, color) in line.fills {
                        context.setFillColor(color)
                        context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
                        context.fillPath()
                    }
                    context.textPosition = CGPoint(x: line.x, y: line.baseline)
                    CTLineDraw(line.ctLine, context)
                    drawnLines += 1
                    for (rect, color) in line.underlines {
                        context.setFillColor(color)
                        context.fill(rect)
                    }
                }
                if row.region != nil { context.restoreGState() }
            }
            for decoration in block.decorations {
                switch decoration {
                case .fill, .stroke: continue
                case let .text(line, origin):
                    context.textPosition = origin
                    CTLineDraw(line, context)
                case let .symbol(image, rect):
                    guard rect.intersects(localVisible) else { continue }
                    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                case let .image(attachmentID, rect, placeholder):
                    guard rect.intersects(localVisible) else { continue }
                    if let source = imageSources[attachmentID]?.image {
                        context.saveGState()
                        context.interpolationQuality = .high
                        source.draw(in: Self.aspectFit(source.size, in: rect), from: .zero, operation: .sourceOver,
                                    fraction: 1, respectFlipped: true, hints: nil)
                        context.restoreGState()
                    } else if let placeholder {
                        let width = CGFloat(CTLineGetTypographicBounds(placeholder, nil, nil, nil))
                        context.textPosition = CGPoint(x: rect.midX - width / 2, y: rect.midY + 4)
                        CTLineDraw(placeholder, context)
                    }
                }
            }
            for (controlIndex, control) in block.controls.enumerated() where control.rect.intersects(localVisible) {
                drawControlForeground(control, key: ControlKey(blockID: item.blockID, index: controlIndex), in: context)
                drawnControls += 1
            }
            context.restoreGState()
        }
        if let tail = tailLine, tail.top - scrollOffset <= dirtyRect.maxY {
            context.textPosition = CGPoint(x: tail.x, y: tail.baseline - scrollOffset)
            CTLineDraw(tail.line, context)
        }
        drawScrollIndicator(in: context)
        qaLastDrawnLineCount = drawnLines
        qaLastDrawnControlCount = drawnControls
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func drawControlBackground(_ control: Control, key: ControlKey, in context: CGContext) {
        let hovered = hoveredControl == key && control.enabled
        let pressed = pressedControl == key && pressedInside && control.enabled
        switch control.style {
        case .choice:
            // `AgentRequestChoiceButton`: every idle choice has equal emphasis;
            // hover (and press) alone use the selected fill.
            let surface = (hovered || pressed) ? AgentSurfaceRole.rowSelected.color : SurfaceToken.overlay.color
            context.setFillColor(surface.cgColor(for: theme))
            let radius = CGFloat(renderContext.pageZoom.scaled(CornerRole.card.radius))
            context.addPath(CGPath(roundedRect: control.rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        case let .region(hoverFill, pressedFill, radius):
            guard let fill = pressed ? (pressedFill ?? hoverFill) : (hovered ? hoverFill : nil) else { return }
            context.setFillColor(fill)
            context.addPath(CGPath(roundedRect: control.rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        case .text, .chevron:
            return
        }
    }

    private func drawControlForeground(_ control: Control, key: ControlKey, in context: CGContext) {
        let pressed = pressedControl == key && pressedInside && control.enabled
        let zoom = renderContext.pageZoom
        let title: String
        switch control.style {
        case let .chevron(expanded): title = expanded ? "\u{25BE}" : "\u{25B8}"
        case .choice, .text: title = control.title
        case .region: title = ""
        }
        if !title.isEmpty {
            let font = control.font ?? NSFont.token(.label, zoom: zoom)
            var tint = control.tint ?? color(control.style.isChoice ? renderContext.tokens.primaryText : renderContext.tokens.secondaryText)
            if !control.enabled { tint = tint.withAlphaComponent(0.4) } else if pressed { tint = tint.withAlphaComponent(0.6) }
            let line = Self.line(title, font: font, color: tint)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let x = control.rect.midX - width / 2
            context.textPosition = CGPoint(x: x, y: Self.centredBaseline(font: font, top: control.rect.minY, height: control.rect.height))
            CTLineDraw(line, context)
        }
        if focusedControl == key {
            context.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor)
            context.setLineWidth(2)
            let ring = control.rect.insetBy(dx: -2, dy: -2)
            context.addPath(CGPath(roundedRect: ring, cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.strokePath()
        }
    }

    private func drawScrollIndicator(in context: CGContext) {
        guard contentHeight > bounds.height, Date() < scrollIndicatorVisibleUntil else { return }
        let knobHeight = max(24, bounds.height * bounds.height / contentHeight)
        let travel = bounds.height - knobHeight - 4
        let fraction = maximumScrollOffset > 0 ? scrollOffset / maximumScrollOffset : 0
        let rect = CGRect(x: bounds.maxX - 9, y: 2 + travel * fraction, width: 6, height: knobHeight)
        context.setFillColor(color(renderContext.tokens.secondaryText).withAlphaComponent(0.45).cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.fillPath()
    }

    private func showScrollIndicator() {
        scrollIndicatorVisibleUntil = Date().addingTimeInterval(1)
        scrollIndicatorTimer?.invalidate()
        scrollIndicatorTimer = Timer.scheduledTimer(withTimeInterval: 1.05, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.needsDisplay = true }
        }
    }

    /// First placed block whose bottom reaches `y`.
    private func firstPlaced(atOrBelow y: CGFloat) -> Int {
        var low = 0, high = placed.count
        while low < high {
            let mid = (low + high) / 2
            if placed[mid].y + placed[mid].block.height < y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: Hit testing

    /// The placed block under a view point, with the point in its local space.
    private func block(at point: NSPoint) -> (index: Int, local: CGPoint)? {
        guard !placed.isEmpty else { return nil }
        let docY = point.y + scrollOffset
        let index = firstPlaced(atOrBelow: docY)
        guard index < placed.count, docY >= placed[index].y else { return nil }
        return (index, CGPoint(x: point.x - insets.left, y: docY - placed[index].y))
    }

    func control(at point: NSPoint) -> (key: ControlKey, control: Control)? {
        guard let hit = block(at: point) else { return nil }
        let item = placed[hit.index]
        for (index, control) in item.block.controls.enumerated().reversed() where control.rect.contains(hit.local) {
            return (ControlKey(blockID: item.blockID, index: index), control)
        }
        return nil
    }

    private func control(for key: ControlKey) -> Control? {
        guard let item = placed.first(where: { $0.blockID == key.blockID }),
              item.block.controls.indices.contains(key.index) else { return nil }
        return item.block.controls[key.index]
    }

    private func region(at point: NSPoint) -> (key: RegionKey, region: ScrollRegion)? {
        guard let hit = block(at: point) else { return nil }
        let item = placed[hit.index]
        for (index, region) in item.block.regions.enumerated() where region.viewport.contains(hit.local) {
            return (RegionKey(blockID: item.blockID, index: index), region)
        }
        return nil
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let dx = precise ? event.scrollingDeltaX : event.scrollingDeltaX * 16
        let dy = precise ? event.scrollingDeltaY : event.scrollingDeltaY * 16
        let point = convert(event.locationInWindow, from: nil)
        // A code body or output pane scrolls on its own first: sideways whenever
        // its lines are wider than it, vertically while it has room to move.
        if let (key, region) = region(at: point) {
            var offset = regionOffsets[key] ?? .zero
            let maxX = max(0, region.contentSize.width - region.viewport.width)
            let maxY = max(0, region.contentSize.height - region.viewport.height)
            if abs(dx) > abs(dy), maxX > 0 {
                offset.x = min(max(0, offset.x - dx), maxX)
                regionOffsets[key] = offset
                needsDisplay = true
                return
            }
            if abs(dy) >= abs(dx), maxY > 0 {
                let next = min(max(0, offset.y - dy), maxY)
                if next != offset.y {
                    offset.y = next
                    regionOffsets[key] = offset
                    needsDisplay = true
                    return
                }
            }
        }
        guard maximumScrollOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }
        scrollTranscript(toY: scrollOffset - dy)
        showScrollIndicator()
    }

    var qaRegionOffsets: [RegionKey: CGPoint] { regionOffsets }

    // MARK: Selection

    private var selectedRange: NSRange? {
        guard let anchor = selectionAnchor, let focus = selectionFocus, anchor != focus else { return nil }
        return NSRange(location: min(anchor, focus), length: abs(anchor - focus))
    }

    /// The document text offset nearest `point` (view coordinates).
    func characterIndex(at point: NSPoint) -> Int? {
        guard !placed.isEmpty else { return nil }
        let docY = point.y + scrollOffset
        var index = min(firstPlaced(atOrBelow: docY), placed.count - 1)
        if docY < placed[index].y, index > 0, docY - (placed[index - 1].y + placed[index - 1].block.height) < placed[index].y - docY {
            index -= 1
        }
        let item = placed[index]
        let local = CGPoint(x: point.x - insets.left, y: docY - item.y)
        var best: (row: Int, line: Line, offset: CGPoint, distance: CGFloat)?
        for (rowIndex, row) in item.block.rows.enumerated() {
            let offset = row.region.map { regionOffsets[RegionKey(blockID: item.blockID, index: $0)] ?? .zero } ?? .zero
            let y = local.y + offset.y
            for line in row.lines {
                let distance = y < line.top ? line.top - y : max(0, y - (line.top + line.height))
                if best == nil || distance < best!.distance { best = (rowIndex, line, offset, distance) }
            }
        }
        guard let best else { return item.textStart }
        var offset = CTLineGetStringIndexForPosition(best.line.ctLine, CGPoint(x: local.x + best.offset.x - best.line.x, y: 0))
        if offset == kCFNotFound { offset = best.line.range.location }
        offset = min(max(offset, best.line.range.location), NSMaxRange(best.line.range))
        return item.textStart + item.block.rowOffsets[best.row] + offset
    }

    /// The row holding document offset `index`.
    private func row(containing index: Int) -> (placed: Placed, row: Int, local: Int)? {
        var low = 0, high = placed.count
        while low < high {
            let mid = (low + high) / 2
            if placed[mid].textStart + placed[mid].block.textLength <= index { low = mid + 1 } else { high = mid }
        }
        guard low < placed.count else { return nil }
        let item = placed[low]
        for rowIndex in item.block.rows.indices.reversed() where item.textStart + item.block.rowOffsets[rowIndex] <= index {
            return (item, rowIndex, index - item.textStart - item.block.rowOffsets[rowIndex])
        }
        return nil
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = control(at: point)
        let key = hit.flatMap { $0.control.enabled ? $0.key : nil }
        if key != hoveredControl {
            hoveredControl = key
            needsDisplay = true
        }
        let overLink = key == nil && characterIndex(at: point).flatMap { link(at: $0) } != nil
            && isPointOverText(point)
        (key != nil || overLink ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredControl != nil {
            hoveredControl = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    private func isPointOverText(_ point: NSPoint) -> Bool {
        guard let index = characterIndex(at: point), let hit = row(containing: index) else { return false }
        let row = hit.placed.block.rows[hit.row]
        let local = CGPoint(x: point.x - insets.left, y: point.y + scrollOffset - hit.placed.y)
        return row.lines.contains { CGRect(x: $0.x, y: $0.top, width: $0.width, height: $0.height).contains(local) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let hit = control(at: point), hit.control.enabled {
            pressedControl = hit.key
            pressedInside = true
            focusedControl = nil
            needsDisplay = true
            return
        }
        focusedControl = nil
        let index = characterIndex(at: point)
        mouseDragged = false
        if event.modifierFlags.contains(.shift), selectionAnchor != nil, let index {
            selectionFocus = index
            mouseDownIndex = nil
        } else {
            mouseDownIndex = index
            selectionAnchor = index
            selectionFocus = index
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let pressed = pressedControl {
            let inside = control(at: point)?.key == pressed
            if inside != pressedInside {
                pressedInside = inside
                needsDisplay = true
            }
            return
        }
        guard selectionAnchor != nil else { return }
        mouseDragged = true
        if point.y < bounds.minY { scrollTranscript(toY: scrollOffset - (bounds.minY - point.y)) }
        if point.y > bounds.maxY { scrollTranscript(toY: scrollOffset + (point.y - bounds.maxY)) }
        if let index = characterIndex(at: point) { selectionFocus = index }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let pressed = pressedControl {
            let point = convert(event.locationInWindow, from: nil)
            pressedControl = nil
            needsDisplay = true
            if control(at: point)?.key == pressed, let control = control(for: pressed) {
                perform(control.action)
            }
            return
        }
        defer { mouseDownIndex = nil }
        guard !mouseDragged, let index = mouseDownIndex else { return }
        selectionAnchor = nil
        selectionFocus = nil
        needsDisplay = true
        if isPointOverText(convert(event.locationInWindow, from: nil)) { _ = activateLink(at: index) }
    }

    /// The one dispatch for every drawn control.
    func perform(_ action: ControlAction) {
        switch action {
        case let .perform(renderAction):
            renderContext.actions.perform(renderAction)
        case let .toggle(id, expanded):
            renderContext.actions.setExpanded(expanded, blockID: id)
        case let .copy(text, blockID):
            pasteboardForCopy.clearContents()
            pasteboardForCopy.setString(text, forType: .string)
            renderContext.actions.perform(.copy(blockID: blockID))
        }
    }

    // MARK: Keyboard

    /// Today's controls are NSButtons: reachable with Tab (under Full Keyboard
    /// Access) and pressed with Space or Return. The drawn controls keep that:
    /// Tab and Shift-Tab walk the enabled controls in document order with a focus
    /// ring; past either end focus leaves the transcript as it would.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48: // Tab
            if moveFocus(backward: event.modifierFlags.contains(.shift)) { return }
        case 49, 36, 76: // Space, Return, Enter
            if let key = focusedControl, let control = control(for: key), control.enabled {
                perform(control.action)
                return
            }
        case 53: // Escape
            if focusedControl != nil || selectedRange != nil {
                focusedControl = nil
                selectionAnchor = nil
                selectionFocus = nil
                needsDisplay = true
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    private var focusOrder: [ControlKey] {
        placed.flatMap { item in
            item.block.controls.enumerated().compactMap { index, control in
                control.enabled ? ControlKey(blockID: item.blockID, index: index) : nil
            }
        }
    }

    @discardableResult
    func moveFocus(backward: Bool) -> Bool {
        let order = focusOrder
        guard !order.isEmpty else { return false }
        let next: Int
        if let current = focusedControl, let position = order.firstIndex(of: current) {
            next = backward ? position - 1 : position + 1
        } else {
            next = backward ? order.count - 1 : 0
        }
        guard order.indices.contains(next) else {
            focusedControl = nil
            needsDisplay = true
            return false
        }
        focusedControl = order[next]
        needsDisplay = true
        return true
    }

    var qaFocusedControlTitle: String? { focusedControl.flatMap { control(for: $0)?.title } }

    // MARK: Links

    private func link(at index: Int) -> (blockID: AgentNodeID, link: AgentTextStyleResolver.LinkRange)? {
        guard let hit = row(containing: index) else { return nil }
        let row = hit.placed.block.rows[hit.row]
        guard let link = row.links.first(where: { NSLocationInRange(hit.local, $0.range) }) else { return nil }
        return (row.ownerID ?? hit.placed.blockID, link)
    }

    /// The same policy `RichInlineTextView.activateLink` applies, re-evaluated at
    /// action time, through the same render actions.
    @discardableResult
    func activateLink(at index: Int, target requestedTarget: AgentLinkOpenTarget? = nil) -> Bool {
        guard let hit = link(at: index) else { return false }
        let blockID = hit.blockID, link = hit.link
        let disposition = AgentLinkPolicy.disposition(for: link.destination)
        if disposition == .openLocalFile {
            renderContext.actions.perform(.openLocalFile(blockID: blockID, destination: link.destination))
            return true
        }
        guard disposition == .openExternally || disposition == .openInternally,
              let url = URL(string: link.destination) else { return false }
        let target: AgentLinkOpenTarget
        if let requestedTarget {
            target = requestedTarget
        } else if disposition == .openExternally, NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            target = .systemBrowser
        } else {
            target = .array
        }
        renderContext.actions.perform(.activateLink(blockID: blockID, url: url, target: target))
        return true
    }

    // MARK: Copy

    /// The selected text, rows joined by newlines.
    var selectedText: String? {
        guard let selection = selectedRange else { return nil }
        var pieces: [String] = []
        let end = NSMaxRange(selection)
        for item in placed where item.textStart < end && item.textStart + item.block.textLength > selection.location {
            for (rowIndex, row) in item.block.rows.enumerated() {
                let rowStart = item.textStart + item.block.rowOffsets[rowIndex]
                let lo = max(selection.location, rowStart)
                let hi = min(end, rowStart + row.string.length)
                guard rowStart < end, rowStart + row.string.length + 1 > selection.location else { continue }
                pieces.append(lo < hi ? (row.string.string as NSString).substring(with: NSRange(location: lo - rowStart, length: hi - lo)) : "")
            }
        }
        return pieces.joined(separator: "\n")
    }

    func select(range: NSRange) {
        selectionAnchor = range.location
        selectionFocus = NSMaxRange(range)
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText, !text.isEmpty else { return }
        pasteboardForCopy.clearContents()
        pasteboardForCopy.setString(text, forType: .string)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let last = placed.last else { return }
        select(range: NSRange(location: 0, length: last.textStart + last.block.textLength - 1))
    }

    @objc private func copyLinkFromMenu(_ sender: NSMenuItem) {
        guard let destination = sender.representedObject as? String else { return }
        pasteboardForCopy.clearContents()
        pasteboardForCopy.setString(destination, forType: .string)
    }

    @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        activateLink(at: index)
    }

    @objc private func performImageAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ImageActionBox else { return }
        renderContext.actions.perform(box.action)
    }

    private final class ImageActionBox: NSObject {
        let action: AgentRenderAction
        init(_ action: AgentRenderAction) { self.action = action }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return selectedRange != nil }
        return menuItem.isEnabled
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Transcript")
        menu.autoenablesItems = false
        let point = convert(event.locationInWindow, from: nil)
        if let hit = block(at: point),
           let image = placed[hit.index].block.images.first(where: { $0.rect.contains(hit.local) }) {
            // `AgentImageCellView`'s menu: each item enabled by what the host can do.
            let available = image.snapshot.state == .available
            let items: [(String, AgentRenderAction, Bool)] = [
                ("Preview", .previewImage(blockID: image.blockID, attachmentID: image.attachmentID), available && image.snapshot.canPreview),
                ("Copy Image", .copyImage(blockID: image.blockID, attachmentID: image.attachmentID), available && image.snapshot.canCopy),
                ("Save As…", .saveImageAs(blockID: image.blockID, attachmentID: image.attachmentID), available && image.snapshot.canSave),
                ("Reveal in Finder", .revealImage(blockID: image.blockID, attachmentID: image.attachmentID), available && image.snapshot.canReveal),
            ]
            for (title, action, enabled) in items {
                let item = NSMenuItem(title: title, action: #selector(performImageAction(_:)), keyEquivalent: "")
                item.representedObject = ImageActionBox(action)
                item.target = self
                item.isEnabled = enabled
                menu.addItem(item)
            }
            return menu
        }
        let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = selectedRange != nil
        menu.addItem(copy)
        if let index = characterIndex(at: point), isPointOverText(point), let link = link(at: index)?.link {
            menu.addItem(.separator())
            let copyLink = NSMenuItem(title: "Copy Link", action: #selector(copyLinkFromMenu(_:)), keyEquivalent: "")
            copyLink.representedObject = link.destination
            copyLink.target = self
            menu.addItem(copyLink)
            let open = NSMenuItem(title: "Open Link", action: #selector(openLinkFromMenu(_:)), keyEquivalent: "")
            open.representedObject = index
            open.target = self
            menu.addItem(open)
        }
        return menu
    }

    // MARK: QA

    /// Every laid row's text in document order, rows joined by newlines.
    var qaLaidOutText: String {
        placed.flatMap { $0.block.rows.map(\.string.string) }.joined(separator: "\n")
    }

    /// The view point at the left edge of document offset `index`, mid-line.
    func qaPoint(forCharacterIndex index: Int) -> NSPoint? {
        guard let hit = row(containing: index) else { return nil }
        let row = hit.placed.block.rows[hit.row]
        guard let line = row.lines.last(where: { $0.range.location <= hit.local }) ?? row.lines.first else { return nil }
        let offset = row.region.map { regionOffsets[RegionKey(blockID: hit.placed.blockID, index: $0)] ?? .zero } ?? .zero
        let x = CTLineGetOffsetForStringIndex(line.ctLine, hit.local, nil)
        return NSPoint(x: insets.left + line.x + x + 0.5 - offset.x,
                       y: hit.placed.y + line.top + line.height / 2 - scrollOffset - offset.y)
    }

    /// Every drawn control as (block, title, style name, centre point in view
    /// coordinates), so a witness can press one through the window.
    var qaControls: [(blockID: AgentNodeID, title: String, kind: String, center: NSPoint)] {
        placed.flatMap { item in
            item.block.controls.map { control in
                let kind: String
                switch control.style {
                case .choice: kind = "choice"
                case .text: kind = "text"
                case let .chevron(expanded): kind = expanded ? "chevron.expanded" : "chevron.collapsed"
                case .region: kind = "region"
                }
                return (item.blockID, control.title, kind,
                        NSPoint(x: insets.left + control.rect.midX, y: item.y + control.rect.midY - scrollOffset))
            }
        }
    }

    /// Scrolls so the given block's top is in view.
    func qaReveal(blockID: AgentNodeID) {
        guard let item = placed.first(where: { $0.blockID == blockID }) else { return }
        scrollTranscript(toY: item.y - insets.top)
    }

    func qaHeight(of blockID: AgentNodeID) -> CGFloat? { placed.first { $0.blockID == blockID }?.block.height }

    // Renderer-agnostic readbacks for `ManagedAgentTileNSView`'s QA seams: what
    // this view laid out and draws, never what the document says it should.

    /// The block exactly as it was laid out: a tool or diff block carries the
    /// presented payload (host-local detail) its drawing was made from. nil when
    /// the block is not laid out.
    func qaPresentedBlock(for blockID: AgentNodeID) -> AgentBlock? {
        guard let item = placed.first(where: { $0.blockID == blockID }),
              var block = document.entries.lazy.flatMap(\.blocks).first(where: { $0.id == blockID }) else { return nil }
        if let presented = item.block.presented { block.payload = presented }
        return block
    }

    /// Waits for the tool-detail snapshot in flight, whose landing re-lays out
    /// the presented rows.
    func qaWaitForToolDetailRefresh() async { await toolDetail.qaWaitForRefresh() }

    /// The working gyro is on screen: shown, animating, at the tail.
    var qaTailGyroVisible: Bool { tailLine != nil && !gyro.isHidden && gyro.isAnimating }

    /// Every selectable text line drawn inside the view's bounds right now: its
    /// string and its rect in view coordinates (lines clipped by a scroll region's
    /// viewport or the view's edge are left out).
    var qaVisibleTextLines: [(text: String, rect: NSRect)] {
        var result: [(String, NSRect)] = []
        for item in placed {
            let top = item.y - scrollOffset
            guard top + item.block.height > 0, top < bounds.height else { continue }
            for row in item.block.rows {
                var offset = CGPoint.zero
                var clip = CGRect(x: 0, y: 0, width: item.block.width, height: item.block.height)
                if let region = row.region, item.block.regions.indices.contains(region) {
                    offset = regionOffsets[RegionKey(blockID: item.blockID, index: region)] ?? .zero
                    clip = item.block.regions[region].viewport
                }
                for line in row.lines {
                    let local = CGRect(x: line.x - offset.x, y: line.top - offset.y, width: line.width, height: line.height)
                    guard clip.contains(local) else { continue }
                    let rect = local.offsetBy(dx: insets.left, dy: top)
                    guard bounds.contains(rect) else { continue }
                    let text = (row.string.string as NSString).substring(with: line.range)
                    result.append((text, rect))
                }
            }
        }
        return result
    }

    /// A one-line boundary block (session boundary, compaction) as drawn: its
    /// label, the width the label was drawn at and the width it needs, the
    /// block's width, and the rules painted beside it.
    struct QABoundary {
        let text: String
        let drawnWidth: CGFloat
        let neededWidth: CGFloat
        let width: CGFloat
        let ruleRects: [CGRect]
    }

    /// A tool row's header as drawn, in view coordinates: the block's frame and
    /// its gaps to its neighbours, the title (string and fonts) and its line
    /// rect, the icon's rect, and the status line's rect and font.
    struct QAToolHeader {
        let frame: NSRect
        let gapAbove: CGFloat?
        let gapBelow: CGFloat?
        let title: NSAttributedString
        let titleRect: NSRect
        let iconRect: NSRect?
        let statusRect: NSRect?
        let statusFont: NSFont?
    }

    func qaToolHeader(for blockID: AgentNodeID) -> QAToolHeader? {
        guard let index = placed.firstIndex(where: { $0.blockID == blockID }) else { return nil }
        let item = placed[index]
        guard let row = item.block.rows.first, let line = row.lines.first else { return nil }
        let origin = CGPoint(x: insets.left, y: item.y - scrollOffset)
        let frame = NSRect(x: origin.x, y: origin.y, width: item.block.width, height: item.block.height)
        let gapAbove = index > 0 ? item.y - (placed[index - 1].y + placed[index - 1].block.height) : nil
        let gapBelow = index + 1 < placed.count ? placed[index + 1].y - (item.y + item.block.height) : nil
        var icon: NSRect?
        var status: (NSRect, NSFont?)?
        for decoration in item.block.decorations {
            switch decoration {
            case let .symbol(_, rect) where icon == nil:
                icon = rect.offsetBy(dx: origin.x, dy: origin.y)
            case let .text(ctLine, baseline) where status == nil:
                var ascent: CGFloat = 0, descent: CGFloat = 0
                let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
                let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
                let font = runs.first.flatMap {
                    (CTRunGetAttributes($0) as NSDictionary)[kCTFontAttributeName as String] as? NSFont
                }
                status = (NSRect(x: origin.x + baseline.x, y: origin.y + baseline.y - ascent,
                                 width: width, height: ascent + descent), font)
            default:
                continue
            }
        }
        return QAToolHeader(
            frame: frame, gapAbove: gapAbove, gapBelow: gapBelow,
            title: row.string.attributedSubstring(from: line.range),
            titleRect: NSRect(x: origin.x + line.x, y: origin.y + line.top, width: line.width, height: line.height),
            iconRect: icon, statusRect: status?.0, statusFont: status?.1)
    }

    func qaBoundary(for blockID: AgentNodeID) -> QABoundary? {
        guard let item = placed.first(where: { $0.blockID == blockID }),
              let row = item.block.rows.first, let line = row.lines.first else { return nil }
        let needed = ceil(Self.width(of: CTLineCreateWithAttributedString(Self.coreTextString(row.string))))
        let rules: [CGRect] = item.block.decorations.compactMap {
            if case let .fill(rect, _, _) = $0, rect.width > 0, rect.height > 0 { return rect }
            return nil
        }
        return QABoundary(text: row.string.string, drawnWidth: line.width, neededWidth: needed,
                          width: item.block.width, ruleRects: rules)
    }
}

extension AgentTranscriptCanvasView.ControlStyle {
    var isChoice: Bool { if case .choice = self { return true }; return false }
}
