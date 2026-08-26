import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// A rendered Markdown surface is made from multiple native text views. AppKit
/// selects inside one text view natively, but has no document selection spanning
/// sibling text systems. The owning surface supplies their document order so a
/// drag that leaves one prose block can continue through the next one.
@MainActor
protocol RichInlineTextSelectionContainer: AnyObject {
    func richInlineTextViewsInSelectionOrder() -> [RichInlineTextView]
}

/// Native selectable transcript text backed by semantic `AgentInline` runs.
/// Parsing, URL opening, and agent ownership deliberately remain outside this
/// view; it reports an authorized semantic action through `AgentRenderContext`.
@MainActor
final class RichInlineTextView: NSTextView, NSTextViewDelegate {
    enum StringPasteboardStyle {
        case plainText
        case markdown
    }

    static let markdownPasteboardType = NSPasteboard.PasteboardType("net.daringfireball.markdown")

    var stringPasteboardStyle: StringPasteboardStyle = .markdown

    private var runs: [AgentInline] = []
    private var renderContext = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private var textRole: TextRole = .body
    private var proseStyle: AgentProseTextStyle = .plain
    private var attributedOverride: NSAttributedString?
    private var blockID: AgentNodeID?
    private(set) var linkRanges: [AgentTextStyleResolver.LinkRange] = []

    /// `.plans/45` T2/T5. The font actually applied to the first rendered glyph.
    ///
    /// The heading-ladder witness reads this rather than the renderer's declared
    /// `textRole`, because the defect it gates is precisely a level that is read
    /// and then discarded: every rung asks for `.title`, so a role-based
    /// assertion agrees with itself and stays green while h1 and h6 are
    /// indistinguishable on screen.
    var qaFirstFontForChecks: NSFont? {
        guard textStorage?.length ?? 0 > 0 else { return nil }
        return textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    /// Companion to `qaFirstFontForChecks`. The heading ladder is expressed in
    /// size, weight AND colour, because the type scale has only three usable
    /// sizes, so a witness that reads size alone cannot see two thirds of it.
    var qaFirstForegroundForChecks: NSColor? {
        guard textStorage?.length ?? 0 > 0 else { return nil }
        return textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureNativeTextView()
    }

    override convenience init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: frameRect.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        self.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureNativeTextView() {
        delegate = self
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        linkTextAttributes = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        setAccessibilityRole(.staticText)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty,
              let window,
              let container = enclosingSelectionContainer(),
              container.richInlineTextViewsInSelectionOrder().count > 1 else {
            super.mouseDown(with: event)
            return
        }
        let initialWindowPoint = event.locationInWindow
        let anchor = characterIndexForSelection(atWindowPoint: initialWindowPoint)
        container.richInlineTextViewsInSelectionOrder().forEach {
            if $0 !== self { $0.setSelectedRange(NSRange(location: 0, length: 0)) }
        }
        window.makeFirstResponder(self)
        var dragged = false
        while let tracked = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if tracked.type == .leftMouseUp { break }
            guard tracked.type == .leftMouseDragged else { continue }
            dragged = dragged || hypot(
                tracked.locationInWindow.x - initialWindowPoint.x,
                tracked.locationInWindow.y - initialWindowPoint.y
            ) >= 2
            guard dragged else { continue }
            _ = autoscroll(with: tracked)
            updateTrackedSelection(
                from: anchor, toWindowPoint: tracked.locationInWindow,
                in: container
            )
        }
        if !dragged {
            if !activateLink(at: anchor) {
                setSelectedRange(NSRange(location: anchor, length: 0))
            }
        }
    }

    func apply(
        runs: [AgentInline],
        blockID: AgentNodeID,
        context: AgentRenderContext,
        textRole: TextRole = .body,
        style: AgentProseTextStyle = .plain
    ) {
        self.runs = runs
        self.blockID = blockID
        renderContext = context
        self.textRole = textRole
        self.proseStyle = style
        repaint()
    }

    /// Compatibility with the temporary semantic-row probes while production
    /// moves from wrapping labels to native TextKit views.
    var stringValue: String { string }
    var isBordered: Bool { false }

    static func measuredHeight(
        for runs: [AgentInline],
        width: CGFloat,
        context: AgentRenderContext,
        textRole: TextRole = .body,
        style: AgentProseTextStyle = .plain
    ) -> CGFloat {
        let availableWidth = max(1, width)
        // The style reaches measurement as well as paint. An indent changes where
        // text wraps, so measuring without it silently clips every wrapped line.
        let attributed = AgentTextStyleResolver.attributedString(
            for: runs,
            theme: context.appearance,
            tokens: context.tokens,
            textRole: textRole,
            style: style
        )
        let rect = attributed.boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let font = NSFont.token(textRole)
        return max(ceil(rect.height), ceil(font.ascender - font.descender + font.leading))
    }

    /// Re-resolves every attribute against the new theme while retaining the
    /// already-parsed semantic runs and current selection.
    func applyTheme(_ theme: TokenTheme) {
        renderContext.appearance = theme
        repaint()
    }

    /// `.plans/45` T8. Renders a caller-composed attributed string instead of
    /// semantic runs.
    ///
    /// A table is laid out with tab stops, which is a paragraph-level decision
    /// the inline resolver has no vocabulary for. Going through this view anyway
    /// is what keeps `_DESIGN.md` §2.5 — "NSTextView, text layout, IME, undo,
    /// selection, accessibility, and pasteboard behavior are retained" — true of
    /// tables: drawing the cells by hand made them unselectable, invisible to
    /// accessibility, and absent from the Markdown tile's rendered text.
    func applyAttributed(
        _ attributed: NSAttributedString,
        blockID: AgentNodeID,
        context: AgentRenderContext
    ) {
        self.runs = []
        self.attributedOverride = attributed
        self.blockID = blockID
        renderContext = context
        repaint()
    }

    static func measuredHeight(for attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let bounding = attributed.boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounding.height)
    }

    private func repaint() {
        if let attributedOverride {
            let selection = selectedRange()
            textStorage?.setAttributedString(attributedOverride)
            linkRanges = []
            let textLength = (string as NSString).length
            let location = min(selection.location, textLength)
            setSelectedRange(NSRange(
                location: location, length: min(selection.length, textLength - location)))
            setAccessibilityLabel(string)
            return
        }
        let selection = selectedRange()
        let resolved = AgentTextStyleResolver.resolve(
            runs,
            theme: renderContext.appearance,
            tokens: renderContext.tokens,
            textRole: textRole,
            style: proseStyle
        )
        textStorage?.setAttributedString(resolved.attributedString)
        textColor = renderContext.tokens.primaryText.color.nsColor(for: renderContext.appearance)
        linkRanges = resolved.links
        let textLength = (string as NSString).length
        let location = min(selection.location, textLength)
        let length = min(selection.length, textLength - location)
        setSelectedRange(NSRange(location: location, length: length))
        setAccessibilityLabel(string)
    }

    /// Re-evaluates pure policy at action time. Display-only and rejected links
    /// never reach the action sink, and a local-file candidate is emitted as its
    /// own semantic action carrying the RAW destination — this view never resolves
    /// a path against a working directory, and never launders a file into a URL
    /// the host would treat as externally authorized.
    @discardableResult
    func activateLink(
        at index: Int,
        context: AgentRenderContext? = nil,
        target requestedTarget: AgentLinkOpenTarget? = nil
    ) -> Bool {
        guard let blockID,
              let link = linkRanges.first(where: { NSLocationInRange(index, $0.range) })
        else { return false }
        let currentDisposition = AgentLinkPolicy.disposition(for: link.destination)
        if currentDisposition == .openLocalFile {
            (context ?? renderContext).actions.perform(
                .openLocalFile(blockID: blockID, destination: link.destination)
            )
            return true
        }
        guard currentDisposition == .openExternally || currentDisposition == .openInternally,
              let url = URL(string: link.destination)
        else { return false }
        let target: AgentLinkOpenTarget
        if let requestedTarget {
            target = requestedTarget
        } else if currentDisposition == .openExternally,
                  NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            target = .systemBrowser
        } else {
            target = .array
        }
        (context ?? renderContext).actions.perform(
            .activateLink(blockID: blockID, url: url, target: target))
        return true
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        activateLink(at: charIndex)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let index = characterIndex(for: event),
              let link = linkRanges.first(where: { NSLocationInRange(index, $0.range) })
        else { return menu }

        menu.addItem(.separator())
        let copy = NSMenuItem(title: "Copy Link", action: #selector(copyLink(_:)), keyEquivalent: "")
        copy.representedObject = link.destination
        copy.target = self
        menu.addItem(copy)

        let disposition = AgentLinkPolicy.disposition(for: link.destination)
        switch disposition {
        case .openExternally, .openInternally, .openLocalFile:
            let title: String
            if disposition == .openLocalFile {
                title = "Open File"
            } else if disposition == .openExternally {
                title = "Open in Array"
            } else {
                title = "Open Link"
            }
            let open = NSMenuItem(title: title, action: #selector(openLink(_:)), keyEquivalent: "")
            open.representedObject = index
            open.target = self
            menu.addItem(open)
            if disposition == .openExternally {
                let external = NSMenuItem(
                    title: "Open in Default Browser",
                    action: #selector(openLinkInSystemBrowser(_:)),
                    keyEquivalent: ""
                )
                external.representedObject = index
                external.target = self
                menu.addItem(external)
            }
        case .displayOnly, .reject:
            break
        }
        return menu
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let destination = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(destination, forType: .string)
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        _ = activateLink(at: index)
    }

    @objc private func openLinkInSystemBrowser(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        _ = activateLink(at: index, target: .systemBrowser)
    }

    private func characterIndex(for event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    override func copy(_ sender: Any?) {
        let selectedViews = enclosingSelectionContainer()?
            .richInlineTextViewsInSelectionOrder()
            .filter { $0.selectedRange().length > 0 } ?? []
        if selectedViews.count > 1 {
            let plain = selectedViews.map { $0.selectedPlainText }.joined(separator: "\n")
            let markdown = selectedViews.map { $0.selectedMarkdown }.joined(separator: "\n")
            writeSelection(plain: plain, markdown: markdown)
            return
        }
        let selection = selectedRange()
        guard selection.length > 0 else { return }
        writeSelection(plain: selectedPlainText, markdown: selectedMarkdown)
    }

    private var selectedPlainText: String {
        (string as NSString).substring(with: selectedRange())
    }

    private var selectedMarkdown: String {
        AgentTextStyleResolver.markdown(for: runs, selectedRange: selectedRange())
    }

    private func writeSelection(plain: String, markdown: String) {
        let stringValue = stringPasteboardStyle == .markdown ? markdown : plain
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, Self.markdownPasteboardType], owner: nil)
        pasteboard.setString(stringValue, forType: .string)
        pasteboard.setString(markdown, forType: Self.markdownPasteboardType)
    }

    private func enclosingSelectionContainer() -> (any RichInlineTextSelectionContainer)? {
        var ancestor = superview
        while let current = ancestor {
            if let container = current as? any RichInlineTextSelectionContainer { return container }
            ancestor = current.superview
        }
        return nil
    }

    private func characterIndexForSelection(atWindowPoint point: NSPoint) -> Int {
        let local = convert(point, from: nil)
        return min(max(0, characterIndexForInsertion(at: local)), (string as NSString).length)
    }

    private func updateTrackedSelection(
        from anchor: Int,
        toWindowPoint point: NSPoint,
        in container: any RichInlineTextSelectionContainer
    ) {
        let views = container.richInlineTextViewsInSelectionOrder().filter { !$0.isHidden && !$0.string.isEmpty }
        guard let sourceIndex = views.firstIndex(where: { $0 === self }) else { return }
        let targetIndex = views.enumerated().min { lhs, rhs in
            selectionDistance(fromWindowPoint: point, to: lhs.element)
                < selectionDistance(fromWindowPoint: point, to: rhs.element)
        }?.offset
        guard let targetIndex else { return }
        if targetIndex == sourceIndex {
            let targetCharacter = characterIndexForSelection(atWindowPoint: point)
            let start = min(anchor, targetCharacter)
            let end = max(anchor, targetCharacter)
            for (index, view) in views.enumerated() {
                view.setSelectedRange(index == sourceIndex
                    ? NSRange(location: start, length: end - start)
                    : NSRange(location: 0, length: 0))
            }
        } else {
            let target = views[targetIndex]
            applyDocumentSelection(
                views: views, sourceIndex: sourceIndex, targetIndex: targetIndex,
                anchor: anchor,
                targetCharacter: target.characterIndexForSelection(atWindowPoint: point)
            )
        }
    }

    /// Deterministic seam for the cross-view range math. Event routing remains
    /// exercised by `mouseDown`; this lets both document owners pin the resulting
    /// native NSTextView selections without manufacturing a tracking loop.
    func qaExtendSelection(to target: RichInlineTextView, anchor: Int, targetCharacter: Int) {
        guard let container = enclosingSelectionContainer() else { return }
        let views = container.richInlineTextViewsInSelectionOrder().filter { !$0.isHidden && !$0.string.isEmpty }
        guard let sourceIndex = views.firstIndex(where: { $0 === self }),
              let targetIndex = views.firstIndex(where: { $0 === target }),
              sourceIndex != targetIndex else { return }
        applyDocumentSelection(
            views: views, sourceIndex: sourceIndex, targetIndex: targetIndex,
            anchor: anchor, targetCharacter: targetCharacter
        )
    }

    private func applyDocumentSelection(
        views: [RichInlineTextView], sourceIndex: Int, targetIndex: Int,
        anchor: Int, targetCharacter: Int
    ) {
        for (index, view) in views.enumerated() {
            let length = (view.string as NSString).length
            let range: NSRange
            if sourceIndex < targetIndex {
                switch index {
                case sourceIndex: range = NSRange(location: min(anchor, length), length: max(0, length - min(anchor, length)))
                case (sourceIndex + 1)..<targetIndex: range = NSRange(location: 0, length: length)
                case targetIndex: range = NSRange(location: 0, length: min(targetCharacter, length))
                default: range = NSRange(location: 0, length: 0)
                }
            } else {
                switch index {
                case targetIndex:
                    let start = min(targetCharacter, length)
                    range = NSRange(location: start, length: max(0, length - start))
                case (targetIndex + 1)..<sourceIndex: range = NSRange(location: 0, length: length)
                case sourceIndex: range = NSRange(location: 0, length: min(anchor, length))
                default: range = NSRange(location: 0, length: 0)
                }
            }
            view.setSelectedRange(range)
        }
    }

    private func selectionDistance(fromWindowPoint point: NSPoint, to view: NSView) -> CGFloat {
        guard view.window != nil else { return .greatestFiniteMagnitude }
        let rect = view.convert(view.bounds, to: nil)
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
