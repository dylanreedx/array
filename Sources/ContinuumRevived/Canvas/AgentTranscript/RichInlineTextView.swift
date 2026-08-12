import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

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
    private var blockID: AgentNodeID?
    private(set) var linkRanges: [AgentTextStyleResolver.LinkRange] = []

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

    func apply(
        runs: [AgentInline],
        blockID: AgentNodeID,
        context: AgentRenderContext,
        textRole: TextRole = .body
    ) {
        self.runs = runs
        self.blockID = blockID
        renderContext = context
        self.textRole = textRole
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
        textRole: TextRole = .body
    ) -> CGFloat {
        let availableWidth = max(1, width)
        let attributed = AgentTextStyleResolver.attributedString(
            for: runs,
            theme: context.appearance,
            tokens: context.tokens,
            textRole: textRole
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

    private func repaint() {
        let selection = selectedRange()
        let resolved = AgentTextStyleResolver.resolve(
            runs,
            theme: renderContext.appearance,
            tokens: renderContext.tokens,
            textRole: textRole
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
    func activateLink(at index: Int, context: AgentRenderContext? = nil) -> Bool {
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
        (context ?? renderContext).actions.perform(.activateLink(blockID: blockID, url: url))
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
            let title = disposition == .openLocalFile ? "Open File" : "Open Link"
            let open = NSMenuItem(title: title, action: #selector(openLink(_:)), keyEquivalent: "")
            open.representedObject = index
            open.target = self
            menu.addItem(open)
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
        let selection = selectedRange()
        guard selection.length > 0 else { return }
        let plain = (string as NSString).substring(with: selection)
        let markdown = AgentTextStyleResolver.markdown(for: runs, selectedRange: selection)
        let stringValue = stringPasteboardStyle == .markdown ? markdown : plain
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, Self.markdownPasteboardType], owner: nil)
        pasteboard.setString(stringValue, forType: .string)
        pasteboard.setString(markdown, forType: Self.markdownPasteboardType)
    }
}
