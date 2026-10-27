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
/// context), and `draw(_:)` strokes the cached `CTLine`s that intersect the dirty
/// rect at whatever scale AppKit hands it. A canvas zoom raises the layer's
/// `contentsScale` and the same lines are drawn again, sharp, with no layout.
///
/// Selected by `ARRAY_TRANSCRIPT_RENDERER=canvas` or the user default
/// `continuum.transcript.renderer = canvas`, read once per tile. Off by default.
///
/// Slice 1 draws prose, user prompts, code, collapsed tool/command rows, session
/// boundaries and the tail status natively; every other block draws its copy text
/// in the secondary style so nothing disappears. Witness:
/// `--transcript-canvas-check` (`TranscriptCanvasChecks`).
@MainActor
final class AgentTranscriptCanvasView: NSView, AgentTranscriptSurface, NSMenuItemValidation {
    // MARK: Switch

    static let rendererEnvironmentKey = "ARRAY_TRANSCRIPT_RENDERER"
    static let rendererDefaultsKey = "continuum.transcript.renderer"

    /// Read by the tile once, at construction.
    static var isSelected: Bool {
        if ProcessInfo.processInfo.environment[rendererEnvironmentKey] == "canvas" { return true }
        return UserDefaults.standard.string(forKey: rendererDefaultsKey) == "canvas"
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
        let x: CGFloat
        let top: CGFloat
        let height: CGFloat
        let baseline: CGFloat
        let width: CGFloat
        let fills: [(CGRect, CGColor)]
        let underlines: [(CGRect, CGColor)]
    }

    /// One selectable run of text: a prose row, a code block, a tool title.
    struct TextRow {
        let string: NSAttributedString
        let lines: [Line]
        let links: [AgentTextStyleResolver.LinkRange]
    }

    enum Decoration {
        case fill(CGRect, CGColor, radius: CGFloat)
        /// Non-selectable text (markers, labels, status), drawn at a baseline.
        case text(CTLine, CGPoint)
        case symbol(NSImage, CGRect)
    }

    final class LaidBlock {
        let id: AgentNodeID
        let revision: UInt64
        let width: CGFloat
        let contextSignature: Int
        let role: AgentEntryRole
        let height: CGFloat
        let rows: [TextRow]
        let decorations: [Decoration]
        let alpha: CGFloat
        let clipsToBounds: Bool
        /// Each row's offset in the block's text; every row is followed by one
        /// separator, which copy renders as a newline.
        let rowOffsets: [Int]
        let textLength: Int

        init(id: AgentNodeID, revision: UInt64, width: CGFloat, contextSignature: Int, role: AgentEntryRole,
             height: CGFloat, rows: [TextRow], decorations: [Decoration], alpha: CGFloat = 1,
             clipsToBounds: Bool = false) {
            self.id = id
            self.revision = revision
            self.width = width
            self.contextSignature = contextSignature
            self.role = role
            self.height = height
            self.rows = rows
            self.decorations = decorations
            self.alpha = alpha
            self.clipsToBounds = clipsToBounds
            var offsets: [Int] = []
            var cursor = 0
            for row in rows {
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

    // MARK: State

    private let toolDetailStore: AgentToolDetailStore?
    private var renderContext = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private let updateScheduler = AgentTranscriptUpdateScheduler()
    private var latestEnqueuedVersion: UInt64?
    private var appliedVersion: UInt64?
    private var document = AgentDocument()
    private var renderingError: Error?

    private var cache: [AgentNodeID: LaidBlock] = [:]
    private var placed: [Placed] = []
    private var contentHeight: CGFloat = 0
    private var laidWidth: CGFloat = -1
    private var scrollOffset: CGFloat = 0
    private let nearBottomThreshold = AgentTranscriptScrollController().nearBottomThreshold

    private var tailVisible = false
    private var tailSettled = false
    private var tailText = ""
    private var tailLine: (line: CTLine, top: CGFloat, baseline: CGFloat, x: CGFloat)?
    private var turnInFlight = false

    /// Selection in document text offsets: `anchor` is where the press began.
    private var selectionAnchor: Int?
    private var selectionFocus: Int?
    private var mouseDownIndex: Int?
    private var mouseDragged = false
    private var scrollIndicatorVisibleUntil: Date = .distantPast
    private var scrollIndicatorTimer: Timer?

    // Tool detail: the store-facing half of the list's capture, without its
    // presentation (output previews and durations come in slice 2).
    private var toolDetailAgentID: AgentID?
    private var activeRuntimeScope: AgentToolDetailScope?
    private var runtimeIdentities: Set<AgentToolDetailKey> = []
    private var toolDetailIdentityByEntryID: [AgentNodeID: AgentToolDetailKey] = [:]

    /// The pasteboard Cmd-C writes. Checks substitute a private one so a witness
    /// never touches the user's clipboard.
    var pasteboardForCopy: NSPasteboard = .general

    // MARK: QA counters

    private(set) var qaBlockLayoutCount = 0
    private(set) var qaLastRelaidBlockIDs: [AgentNodeID] = []
    private(set) var qaFullRelayoutCount = 0
    private(set) var qaDrawCount = 0
    private(set) var qaLastDrawScale: CGFloat = 0
    private(set) var qaLastDrawnLineCount = 0
    private(set) var qaRuntimeObservationCount = 0
    var qaRenderingErrorDescription: String? { renderingError.map(String.init(describing:)) }
    var qaScrollOffset: CGFloat { scrollOffset }
    var qaMaximumScrollOffset: CGFloat { maximumScrollOffset }
    var qaContentHeight: CGFloat { contentHeight }
    var qaPlacedBlockIDs: [AgentNodeID] { placed.map(\.blockID) }

    // MARK: Init

    init(toolDetailStore: AgentToolDetailStore? = nil) {
        self.toolDetailStore = toolDetailStore
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        updateScheduler.isPresentable = { [weak self] in self?.isOnScreenForVisualUpdates ?? true }
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
        needsDisplay = true
    }

    func updateRenderContext(_ context: AgentRenderContext) throws {
        let moved = Self.signature(of: context) != Self.signature(of: renderContext)
            || context.tokens != renderContext.tokens
        renderContext = context
        guard moved else { return }
        cache.removeAll()
        preservingTail { rebuild() }
    }

    func bindToolDetailAgent(_ agentID: AgentID?) {
        toolDetailAgentID = agentID
        activeRuntimeScope = nil
        runtimeIdentities.removeAll()
    }

    func captureRuntimeObservation(_ observation: AgentRuntimeObservation) {
        // Accepted and counted; slice 1 presents no tool detail from them.
        qaRuntimeObservationCount += 1
    }

    @discardableResult
    func captureRuntimeEvent(_ event: AgentRuntimeEvent) -> AgentToolDetailKey? {
        guard let toolDetailStore else { return nil }
        switch event {
        case let .turnStarted(threadID, turnID):
            activeRuntimeScope = toolDetailAgentID.flatMap {
                AgentToolDetailScope(agentID: $0.rawValue.uuidString, threadID: threadID, turnID: turnID, provider: "runtime")
            }
            if let scope = activeRuntimeScope { runtimeIdentities = runtimeIdentities.filter { $0.scope == scope } }
            return nil
        case let .itemStarted(threadID, itemID, kind, title):
            guard AgentToolDetailPolicy.carriesHostLocalDetail(kind),
                  let providerID = AgentToolDetailID(itemID),
                  let scope = activeRuntimeScope, scope.threadID == threadID else { return nil }
            let identity = AgentToolDetailKey(scope: scope, providerItemID: providerID)
            runtimeIdentities.insert(identity)
            let start = AgentToolDetailStart(identity: identity, toolName: title ?? "Tool")
            Task { _ = await toolDetailStore.recordStart(start) }
            return identity
        case let .itemCompleted(threadID, itemID, kind, status):
            guard AgentToolDetailPolicy.carriesHostLocalDetail(kind),
                  let providerID = AgentToolDetailID(itemID),
                  let scope = activeRuntimeScope, scope.threadID == threadID else { return nil }
            let identity = AgentToolDetailKey(scope: scope, providerItemID: providerID)
            guard runtimeIdentities.contains(identity) else { return nil }
            let mapped: AgentItemStatus = status == .failed ? .failed : (status == .declined ? .cancelled : .completed)
            Task { _ = await toolDetailStore.recordEnd(AgentToolDetailEnd(identity: identity, status: mapped)) }
            return nil
        default:
            return nil
        }
    }

    func bindToolDetailIdentity(_ identity: AgentToolDetailKey, to entryID: AgentNodeID) -> Bool {
        if let toolDetailAgentID, identity.scope.agentID != toolDetailAgentID.rawValue.uuidString { return false }
        guard let existing = toolDetailIdentityByEntryID[entryID] else {
            toolDetailIdentityByEntryID[entryID] = identity
            return true
        }
        return existing == identity
    }

    func setThinkingIndicatorVisible(_ visible: Bool) {
        let changed = tailVisible != visible || tailSettled
        tailSettled = false
        tailVisible = visible
        if !visible { tailText = "" }
        if changed { preservingTail { placeTail() } }
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
    }

    var qaTailStatusText: String { tailText }

    var transcriptScrollOrigin: CGPoint { CGPoint(x: 0, y: scrollOffset) }

    func scrollTranscript(toY y: CGFloat) {
        scrollOffset = min(max(0, y), maximumScrollOffset)
        needsDisplay = true
    }

    // MARK: Geometry

    private var insets: NSEdgeInsets {
        let zoom = renderContext.pageZoom
        let value = CGFloat(zoom.scaled(12))
        return NSEdgeInsets(top: value, left: value, bottom: value, right: value)
    }

    private var columnWidth: CGFloat { max(1, bounds.width - insets.left - insets.right) }

    private var maximumScrollOffset: CGFloat { max(0, contentHeight - bounds.height) }

    private var isNearBottom: Bool { maximumScrollOffset - scrollOffset <= nearBottomThreshold }

    /// Runs a geometry change; a reader at the bottom stays at the bottom, anyone
    /// else keeps their offset (clamped).
    private func preservingTail(_ change: () -> Void) {
        let stick = isNearBottom
        change()
        scrollOffset = stick ? maximumScrollOffset : min(scrollOffset, maximumScrollOffset)
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

    private static func signature(of context: AgentRenderContext) -> Int {
        var hasher = Hasher()
        hasher.combine(context.appearance.rawValue)
        hasher.combine(context.pageZoom.percent)
        return hasher.finalize()
    }

    /// Walk the document; lay out only blocks the cache cannot answer; place all.
    /// Never called from `draw`.
    private func rebuild() {
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
        var previousRole: AgentEntryRole?
        for entry in document.entries {
            // Open reasoning is shown by the tail status, as in the list.
            if entry.role == .reasoning, entry.lifecycle != .finished { continue }
            let blocks = entry.blocks
            for (index, block) in blocks.enumerated() {
                let laid: LaidBlock
                if let cached = cache[block.id], cached.revision == block.revision, cached.width == width,
                   cached.contextSignature == signature, cached.role == entry.role {
                    laid = cached
                } else {
                    laid = layoutBlock(block, role: entry.role, width: width, signature: signature)
                    relaid.append(block.id)
                }
                next[block.id] = laid
                if !result.isEmpty {
                    let startsTurn = index == 0 && entry.role == .user && previousRole != .user
                    y += startsTurn ? turnSpacing : rowSpacing
                }
                result.append(Placed(block: laid, y: y, textStart: text, blockID: block.id))
                y += laid.height
                text += laid.textLength
            }
            if !blocks.isEmpty { previousRole = entry.role }
        }
        cache = next
        placed = result
        blocksBottom = y
        qaBlockLayoutCount += relaid.count
        qaLastRelaidBlockIDs = relaid
        placeTail()
        if let anchor = selectionAnchor, anchor > text { selectionAnchor = nil; selectionFocus = nil }
    }

    private var blocksBottom: CGFloat = 0

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
    }

    // MARK: Block layout

    private var theme: TokenTheme { renderContext.appearance }
    private func color(_ token: TextToken) -> NSColor { token.color.nsColor(for: theme) }

    private func layoutBlock(_ block: AgentBlock, role: AgentEntryRole, width: CGFloat, signature: Int) -> LaidBlock {
        if role != .reasoning {
            if AssistantProseRenderer.supportedKinds.contains(block.kind) {
                return layoutProse(block, role: role, width: width, signature: signature)
            }
            switch block.payload {
            case let .fencedCode(code):
                return layoutCode(block, code: code, role: role, width: width, signature: signature)
            case let .toolCall(tool):
                return layoutTool(block, tool: tool, role: role, width: width, signature: signature)
            case let .commandOutput(output):
                return layoutCommandOutput(block, output: output, role: role, width: width, signature: signature)
            case let .sessionBoundary(boundary):
                return layoutBoundary(block, text: boundary.text, symbolName: boundary.symbolName,
                                      role: role, width: width, signature: signature)
            default:
                break
            }
        }
        return layoutPlain(block, role: role, width: width, signature: signature)
    }

    private func layoutProse(_ block: AgentBlock, role: AgentEntryRole, width: CGFloat, signature: Int) -> LaidBlock {
        let zoom = renderContext.pageZoom
        let isUser = role == .user
        let leading = isUser ? UserPromptView.leadingInset(zoom: zoom) : 0
        let vertical = isUser ? UserPromptView.verticalInset(zoom: zoom) : 0
        let textWidth = max(1, width - leading)
        var rows: [TextRow] = []
        var decorations: [Decoration] = []
        var y = vertical
        let proseRows = AssistantProseView.rows(for: block, zoom: zoom)
        for (index, row) in proseRows.enumerated() {
            if index > 0 { y += AssistantProseView.blockSpacing(zoom: zoom) + row.spacingAbove }
            let resolved = AgentTextStyleResolver.resolve(
                row.runs, theme: theme, tokens: renderContext.tokens, textRole: row.textRole,
                style: row.style, zoom: zoom)
            let font = NSFont.token(row.textRole, zoom: zoom)
            let set = Self.typeset(
                resolved.attributedString, width: textWidth, originX: leading, top: y,
                firstIndent: row.style.firstLineHeadIndent, headIndent: row.style.headIndent,
                linePitch: row.style.linePitch, fallbackFont: font)
            rows.append(TextRow(string: resolved.attributedString, lines: set.lines, links: resolved.links))
            if !row.marker.isEmpty {
                let marker = CTLineCreateWithAttributedString(Self.coreTextString(NSAttributedString(
                    string: row.marker, attributes: [.font: font, .foregroundColor: color(renderContext.tokens.secondaryText)])))
                let x = leading + row.style.firstLineHeadIndent - AssistantProseView.markerGutter(zoom: zoom)
                let baseline = set.lines.first?.baseline ?? (y + font.ascender)
                decorations.append(.text(marker, CGPoint(x: max(leading, x), y: baseline)))
            }
            y += set.height
        }
        let height = ceil(y + vertical)
        if isUser {
            decorations.insert(.fill(
                CGRect(x: 0, y: 0, width: UserPromptView.ruleWidth(zoom: zoom), height: height),
                AgentLineRole.authorship.color.cgColor(for: theme), radius: 0), at: 0)
        }
        return LaidBlock(id: block.id, revision: block.revision, width: width, contextSignature: signature,
                         role: role, height: height, rows: rows, decorations: decorations)
    }

    private func layoutCode(_ block: AgentBlock, code: AgentCodePayload, role: AgentEntryRole,
                            width: CGFloat, signature: Int) -> LaidBlock {
        let zoom = renderContext.pageZoom
        let header = CodeBlockView.headerHeight(zoom: zoom)
        let inset = CodeTextView.containerInset(zoom: zoom)
        let side = CGFloat(zoom.scaled(Space.l))
        let mono = NSFont.token(.bodyMono, zoom: zoom)
        let lineHeight = ceil(mono.ascender - mono.descender + mono.leading)
        let string = NSAttributedString(string: code.code, attributes: [
            .font: mono, .foregroundColor: color(renderContext.tokens.primaryText)])
        let typesetter = CTTypesetterCreateWithAttributedString(Self.coreTextString(string))
        var lines: [Line] = []
        let ns = code.code as NSString
        var location = 0
        var top = header + inset.height
        repeat {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            var visible = paragraph
            while visible.length > 0, let scalar = UnicodeScalar(ns.character(at: NSMaxRange(visible) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                visible.length -= 1
            }
            // Lines keep their offsets in the whole code string, so selection and
            // hit testing index the row's text directly.
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: visible.location, length: visible.length))
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            lines.append(Line(ctLine: line, range: visible, x: inset.width, top: top, height: lineHeight,
                              baseline: top + mono.ascender, width: lineWidth, fills: [], underlines: []))
            top += lineHeight
            location = NSMaxRange(paragraph)
        } while location < ns.length
        let codeHeight = max(CodeBlockView.minimumCodeHeight(zoom: zoom), CGFloat(lines.count) * lineHeight + inset.height * 2)
        let height = ceil(header + codeHeight)
        let labelFont = NSFont.token(.label, zoom: zoom)
        let secondary = color(renderContext.tokens.secondaryText)
        let language = code.language?.trimmingCharacters(in: .whitespacesAndNewlines)
        var decorations: [Decoration] = [
            .fill(CGRect(x: 0, y: 0, width: width, height: height),
                  renderContext.tokens.codeSurface.color.cgColor(for: theme),
                  radius: CGFloat(zoom.scaled(CornerRole.artifact.radius))),
            .text(Self.line("\(language.flatMap { $0.isEmpty ? nil : $0 } ?? "Code")", font: labelFont, color: secondary),
                  CGPoint(x: side, y: CGFloat(zoom.scaled(Space.m)) + labelFont.ascender)),
        ]
        if !code.isComplete {
            let caption = NSFont.token(.caption, zoom: zoom)
            let streaming = Self.line("Streaming", font: caption, color: secondary)
            let streamingWidth = CGFloat(CTLineGetTypographicBounds(streaming, nil, nil, nil))
            decorations.append(.text(streaming, CGPoint(x: width - side - streamingWidth,
                                                        y: CGFloat(zoom.scaled(Space.m)) + caption.ascender)))
        }
        return LaidBlock(id: block.id, revision: block.revision, width: width, contextSignature: signature,
                         role: role, height: height,
                         rows: [TextRow(string: string, lines: lines, links: [])],
                         decorations: decorations, clipsToBounds: true)
    }

    /// A collapsed tool row, in the same geometry `ToolCallView.layout()` uses:
    /// disclosure column, icon, title, trailing status, and the one-line summary.
    private func layoutTool(_ block: AgentBlock, tool: AgentToolCallPayload, role: AgentEntryRole,
                            width: CGFloat, signature: Int) -> LaidBlock {
        let shell = tool.presentedShell.flatMap { $0.command.isEmpty ? nil : $0 }
        let title = ToolCallView.safeSingleLine(tool.name, fallback: "Tool")
        let status = tool.presentedShell == nil
            ? ToolCallView.statusText(status: tool.status, duration: tool.presentedTrailingDetailText)
            : ToolCallView.shellStatusText(
                status: ToolCallView.glyphStatus(tool.status, shell: tool.presentedShell),
                duration: tool.presentedTrailingDetailText, badge: tool.presentedShell?.badgeText)
        let needsAttention = tool.status == .failed || tool.presentedShell?.needsAttention == true
        let summary = ToolCallView.presentedSummary(
            title: title, summary: tool.summary, statusLabel: tool.status.agentToolStatusPresentation.label,
            shell: shell, hasOutput: tool.presentedOutputText?.isEmpty == false).compactLine
        let symbol = ToolCallView.symbolName(forToolNamed: tool.presentedToolNameText ?? tool.name)
        let zoom = renderContext.pageZoom
        return layoutHeaderRow(
            block, role: role, width: width, signature: signature,
            title: title, titleFont: shell == nil ? NSFont.token(.label, zoom: zoom) : ToolCallView.commandFont(zoom: zoom),
            status: status, statusAttention: needsAttention, symbolName: symbol,
            summary: summary, summaryFont: NSFont.token(shell == nil ? .body : .bodyMono, zoom: zoom),
            alpha: tool.status.agentToolIsTerminal && !needsAttention ? CGFloat(Opacity.receded) : 1)
    }

    private func layoutCommandOutput(_ block: AgentBlock, output: AgentCommandOutputPayload, role: AgentEntryRole,
                                     width: CGFloat, signature: Int) -> LaidBlock {
        let presentation = output.status.agentToolStatusPresentation
        let status = output.exitCode.map { "\(presentation.glyph) \(presentation.label), exit \($0)" }
            ?? "\(presentation.glyph) \(presentation.label)"
        return layoutHeaderRow(
            block, role: role, width: width, signature: signature,
            title: "Command output", titleFont: NSFont.token(.label, zoom: renderContext.pageZoom),
            status: status, statusAttention: output.status == .failed, symbolName: "terminal",
            summary: "", summaryFont: NSFont.token(.body, zoom: renderContext.pageZoom),
            alpha: output.status.agentToolIsTerminal && output.status != .failed ? CGFloat(Opacity.receded) : 1)
    }

    private func layoutHeaderRow(
        _ block: AgentBlock, role: AgentEntryRole, width: CGFloat, signature: Int,
        title: String, titleFont: NSFont, status: String, statusAttention: Bool, symbolName: String,
        summary: String, summaryFont: NSFont, alpha: CGFloat
    ) -> LaidBlock {
        let zoom = renderContext.pageZoom
        let rowHeight = ToolCallView.rowHeight(zoom: zoom)
        let inset = ToolCallView.horizontalInset(zoom: zoom)
        let buttonSide = CGFloat(zoom.scaled(Space.xxl))
        let primary = color(renderContext.tokens.primaryText)
        let secondary = color(renderContext.tokens.secondaryText)
        var decorations: [Decoration] = []

        let iconX = inset + buttonSide + CGFloat(zoom.scaled(Space.s))
        if let icon = Self.symbol(symbolName, pointSize: CGFloat(zoom.scaled(13)), color: secondary) {
            let size = icon.size
            decorations.append(.symbol(icon, CGRect(
                x: iconX + (buttonSide - size.width) / 2, y: (rowHeight - size.height) / 2,
                width: size.width, height: size.height)))
        }
        let captionFont = NSFont.token(.caption, zoom: zoom)
        let statusLine = Self.line(status, font: captionFont,
                                   color: statusAttention ? AgentLineRole.attention.color.nsColor(for: theme) : secondary)
        let statusWidth = min(ceil(CGFloat(CTLineGetTypographicBounds(statusLine, nil, nil, nil))), width * 0.4)
        let statusX = max(iconX + buttonSide, width - inset - statusWidth)
        decorations.append(.text(statusLine, CGPoint(
            x: statusX, y: Self.centredBaseline(font: captionFont, top: 0, height: rowHeight))))

        let titleX = iconX + buttonSide + CGFloat(zoom.scaled(Space.m))
        let titleWidth = max(1, statusX - titleX - CGFloat(zoom.scaled(Space.m)))
        var rows: [TextRow] = []
        let titleString = NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: primary])
        rows.append(TextRow(string: titleString, lines: [Self.singleLine(
            titleString, x: titleX, top: 0, height: rowHeight, maxWidth: titleWidth, font: titleFont)], links: []))
        var height = rowHeight
        if !summary.isEmpty {
            let indent = ToolCallView.detailIndent(zoom: zoom)
            let lineHeight = ceil(summaryFont.ascender - summaryFont.descender + summaryFont.leading)
            let summaryString = NSAttributedString(string: summary, attributes: [.font: summaryFont, .foregroundColor: primary])
            rows.append(TextRow(string: summaryString, lines: [Self.singleLine(
                summaryString, x: indent, top: rowHeight, height: lineHeight,
                maxWidth: max(1, width - indent - inset), font: summaryFont)], links: []))
            height += lineHeight + ToolCallView.detailBottomInset(zoom: zoom)
        }
        return LaidBlock(id: block.id, revision: block.revision, width: width, contextSignature: signature,
                         role: role, height: ceil(height), rows: rows, decorations: decorations, alpha: alpha)
    }

    private func layoutBoundary(_ block: AgentBlock, text: String, symbolName: String?, role: AgentEntryRole,
                                width: CGFloat, signature: Int) -> LaidBlock {
        let zoom = renderContext.pageZoom
        let height = CGFloat(zoom.scaled(28))
        let font = NSFont.systemFont(ofSize: CGFloat(zoom.scaled(11)), weight: .medium)
        let secondary = color(renderContext.tokens.secondaryText)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: secondary])
        let gap = CGFloat(zoom.scaled(Space.m))
        let icon = symbolName.flatMap { Self.symbol($0, pointSize: font.pointSize, color: secondary) }
        let glyphLead = icon.map { $0.size.width + CGFloat(zoom.scaled(Space.s)) } ?? 0
        let measured = CTLineCreateWithAttributedString(Self.coreTextString(string))
        let labelWidth = min(ceil(CGFloat(CTLineGetTypographicBounds(measured, nil, nil, nil))),
                             max(0, width - 2 * gap - glyphLead))
        let groupX = ((width - labelWidth - glyphLead) / 2).rounded()
        var decorations: [Decoration] = []
        let rule = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        let hairline = max(CGFloat(LineWidth.hairline), 0.5)
        decorations.append(.fill(CGRect(x: 0, y: (height - hairline) / 2, width: max(0, groupX - gap), height: hairline), rule, radius: 0))
        decorations.append(.fill(CGRect(x: groupX + glyphLead + labelWidth + gap, y: (height - hairline) / 2,
                                        width: max(0, width - groupX - glyphLead - labelWidth - gap), height: hairline), rule, radius: 0))
        if let icon {
            decorations.append(.symbol(icon, CGRect(x: groupX, y: (height - icon.size.height) / 2,
                                                    width: icon.size.width, height: icon.size.height)))
        }
        let line = Self.singleLine(string, x: groupX + glyphLead, top: 0, height: height, maxWidth: max(1, labelWidth), font: font)
        return LaidBlock(id: block.id, revision: block.revision, width: width, contextSignature: signature,
                         role: role, height: height, rows: [TextRow(string: string, lines: [line], links: [])],
                         decorations: decorations)
    }

    /// Every block slice 1 does not draw natively: its copy text, secondary, so
    /// nothing a provider sent ever disappears.
    private func layoutPlain(_ block: AgentBlock, role: AgentEntryRole, width: CGFloat, signature: Int) -> LaidBlock {
        let zoom = renderContext.pageZoom
        let font = NSFont.token(.body, zoom: zoom)
        let text = AgentTranscriptCopyController.plainText(for: [block])
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color(renderContext.tokens.secondaryText)])
        let set = Self.typeset(string, width: width, originX: 0, top: 0, firstIndent: 0, headIndent: 0,
                               linePitch: AssistantProseView.bodyLinePitch(zoom: zoom), fallbackFont: font)
        return LaidBlock(id: block.id, revision: block.revision, width: width, contextSignature: signature,
                         role: role, height: ceil(set.height), rows: [TextRow(string: string, lines: set.lines, links: [])],
                         decorations: [])
    }

    // MARK: CoreText helpers

    /// CoreText reads its own colour key; AppKit's `.foregroundColor` is copied
    /// across as a CGColor so CTLineDraw paints the token colour.
    static func coreTextString(_ string: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: string)
        string.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let color = value as? NSColor else { return }
            copy.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: color.cgColor, range: range)
        }
        return copy
    }

    private static func line(_ text: String, font: NSFont, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(coreTextString(NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color])))
    }

    private static func centredBaseline(font: NSFont, top: CGFloat, height: CGFloat) -> CGFloat {
        top + ((height - (font.ascender - font.descender)) / 2).rounded() + font.ascender
    }

    /// A one-line row, truncated with an ellipsis to `maxWidth`.
    private static func singleLine(_ string: NSAttributedString, x: CGFloat, top: CGFloat, height: CGFloat,
                                   maxWidth: CGFloat, font: NSFont) -> Line {
        let ct = coreTextString(string)
        var line = CTLineCreateWithAttributedString(ct)
        if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth {
            let token = CTLineCreateWithAttributedString(NSAttributedString(
                string: "\u{2026}", attributes: ct.attributes(at: 0, effectiveRange: nil)))
            line = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, token) ?? line
        }
        return Line(ctLine: line, range: NSRange(location: 0, length: string.length), x: x, top: top,
                    height: height, baseline: centredBaseline(font: font, top: top, height: height),
                    width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), fills: [], underlines: [])
    }

    /// Wraps `string` into lines with the given indents and pitch. Inline code
    /// fills and link underlines are resolved here, once, so draw only strokes.
    static func typeset(
        _ string: NSAttributedString, width: CGFloat, originX: CGFloat, top: CGFloat,
        firstIndent: CGFloat, headIndent: CGFloat, linePitch: CGFloat, fallbackFont: NSFont
    ) -> (lines: [Line], height: CGFloat) {
        let naturalFallback = ceil(fallbackFont.ascender - fallbackFont.descender + fallbackFont.leading)
        guard string.length > 0 else { return ([], max(naturalFallback, linePitch)) }
        let ct = coreTextString(string)
        let typesetter = CTTypesetterCreateWithAttributedString(ct)
        var lines: [Line] = []
        var start = 0
        var y = top
        while start < string.length {
            let indent = lines.isEmpty ? firstIndent : headIndent
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width - indent)))
            if count <= 0 { count = 1 }
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            let natural = ceil(ascent + descent + leading)
            let height = linePitch > 0 ? max(linePitch, ceil(ascent + descent)) : natural
            let baseline = y + ((height - (ascent + descent)) / 2).rounded() + ascent
            let x = originX + indent
            var fills: [(CGRect, CGColor)] = []
            var underlines: [(CGRect, CGColor)] = []
            for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? [] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let range = CTRunGetStringRange(run)
                let x1 = CTLineGetOffsetForStringIndex(ctLine, range.location, nil)
                let x2 = CTLineGetOffsetForStringIndex(ctLine, range.location + range.length, nil)
                guard x2 > x1 else { continue }
                if let background = attributes[NSAttributedString.Key.backgroundColor] as? NSColor {
                    fills.append((CGRect(x: x + x1 - 2, y: baseline - ascent - 1, width: x2 - x1 + 4,
                                         height: ascent + descent + 2), background.cgColor))
                }
                if let underline = attributes[NSAttributedString.Key.underlineStyle] as? Int, underline != 0 {
                    let color = (attributes[NSAttributedString.Key.foregroundColor] as? NSColor)?.cgColor
                        ?? NSColor.labelColor.cgColor
                    underlines.append((CGRect(x: x + x1, y: baseline + 1.5, width: x2 - x1, height: 1), color))
                }
            }
            lines.append(Line(ctLine: ctLine, range: NSRange(location: start, length: count), x: x, top: y,
                              height: height, baseline: baseline, width: lineWidth, fills: fills, underlines: underlines))
            y += height
            start += count
        }
        return (lines, max(y - top, naturalFallback))
    }

    /// A vector SF Symbol in one colour. Drawn per frame, so it stays sharp at any
    /// zoom (`CanvasSymbolImage` rasterizes, which a canvas zoom would scale).
    private static var symbolCache: [String: NSImage] = [:]
    private static func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(name)|\(pointSize)|\(color.cgColor.components ?? [])"
        if let cached = symbolCache[key] { return cached }
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: ToolCallView.fallbackSymbolName, accessibilityDescription: nil)
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = base?.withSymbolConfiguration(configuration) else { return nil }
        symbolCache[key] = image
        return image
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        qaDrawCount += 1
        // The device transform carries the layer's contentsScale (the CTM does
        // not, under Core Animation's drawing contexts).
        let device = context.userSpaceToDeviceSpaceTransform
        qaLastDrawScale = hypot(device.a, device.b)
        let x0 = insets.left
        let visible = dirtyRect.offsetBy(dx: 0, dy: scrollOffset)
        let selection = selectedRange
        let highlight = NSColor.selectedTextBackgroundColor.cgColor
        var drawnLines = 0
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
                if case let .fill(rect, color, radius) = decoration, rect.intersects(localVisible) {
                    context.setFillColor(color)
                    if radius > 0 {
                        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                        context.fillPath()
                    } else {
                        context.fill(rect)
                    }
                }
            }
            if block.clipsToBounds { context.clip(to: CGRect(x: 0, y: 0, width: block.width, height: block.height)) }
            for (rowIndex, row) in block.rows.enumerated() {
                let rowStart = item.textStart + block.rowOffsets[rowIndex]
                for line in row.lines {
                    guard line.top + line.height >= localVisible.minY, line.top <= localVisible.maxY else { continue }
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
            }
            for decoration in block.decorations {
                switch decoration {
                case .fill: continue
                case let .text(line, origin):
                    context.textPosition = origin
                    CTLineDraw(line, context)
                case let .symbol(image, rect):
                    guard rect.intersects(localVisible) else { continue }
                    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            context.restoreGState()
        }
        if let tail = tailLine, tail.top - scrollOffset <= dirtyRect.maxY {
            context.textPosition = CGPoint(x: tail.x, y: tail.baseline - scrollOffset)
            CTLineDraw(tail.line, context)
        }
        drawScrollIndicator(in: context)
        qaLastDrawnLineCount = drawnLines
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

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard maximumScrollOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
        scrollTranscript(toY: scrollOffset - delta)
        showScrollIndicator()
    }

    // MARK: Hit testing and selection

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
        var best: (row: Int, line: Line, distance: CGFloat)?
        for (rowIndex, row) in item.block.rows.enumerated() {
            for line in row.lines {
                let distance = local.y < line.top ? line.top - local.y : max(0, local.y - (line.top + line.height))
                if best == nil || distance < best!.distance { best = (rowIndex, line, distance) }
            }
        }
        guard let best else { return item.textStart }
        var offset = CTLineGetStringIndexForPosition(best.line.ctLine, CGPoint(x: local.x - best.line.x, y: 0))
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
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
        guard selectionAnchor != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        mouseDragged = true
        if point.y < bounds.minY { scrollTranscript(toY: scrollOffset - (bounds.minY - point.y)) }
        if point.y > bounds.maxY { scrollTranscript(toY: scrollOffset + (point.y - bounds.maxY)) }
        if let index = characterIndex(at: point) { selectionFocus = index }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownIndex = nil }
        guard !mouseDragged, let index = mouseDownIndex else { return }
        selectionAnchor = nil
        selectionFocus = nil
        needsDisplay = true
        _ = activateLink(at: index)
    }

    private func link(at index: Int) -> (blockID: AgentNodeID, link: AgentTextStyleResolver.LinkRange)? {
        guard let hit = row(containing: index) else { return nil }
        let row = hit.placed.block.rows[hit.row]
        guard let link = row.links.first(where: { NSLocationInRange(hit.local, $0.range) }) else { return nil }
        return (hit.placed.blockID, link)
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return selectedRange != nil }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Transcript")
        let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let point = convert(event.locationInWindow, from: nil)
        if let index = characterIndex(at: point), let link = link(at: index)?.link {
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
        let x = CTLineGetOffsetForStringIndex(line.ctLine, hit.local, nil)
        return NSPoint(x: insets.left + line.x + x + 0.5,
                       y: hit.placed.y + line.top + line.height / 2 - scrollOffset)
    }
}
