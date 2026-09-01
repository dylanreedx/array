import AppKit
import ContinuumRevivedAgentUI

/// The token vocabulary intentionally contains only plain code in this ticket.
/// A later highlighter can add semantic tokens without changing the renderer,
/// semantic document, or TextKit ownership.
enum CodeHighlightToken: Equatable {
    case plain
}

struct HighlightSpan: Equatable {
    var range: NSRange
    var token: CodeHighlightToken

    init(range: NSRange, token: CodeHighlightToken = .plain) {
        self.range = range
        self.token = token
    }
}

protocol CodeHighlighting {
    func spans(language: String?, code: String) -> [HighlightSpan]
}

struct PlainCodeHighlighter: CodeHighlighting {
    func spans(language: String?, code: String) -> [HighlightSpan] {
        let length = (code as NSString).length
        return length == 0 ? [] : [HighlightSpan(range: NSRange(location: 0, length: length))]
    }
}

/// A native, inert code surface. The text container never wraps, so indentation
/// and long lines remain visible through the enclosing horizontal scroller.
@MainActor
final class CodeTextView: NSTextView {
    private let highlighter: any CodeHighlighting
    private var language: String?
    private var theme: TokenTheme = .dark
    private var tokens: AgentRenderTokens = .transcript
    /// WS5: the page zoom of the last `apply(code:language:context:)`. A code
    /// view is recycled, so the container inset and the mono font are re-derived
    /// on every apply rather than frozen at construction.
    private var pageZoom: AgentPageZoom = .default

    private(set) var appliedSpans: [HighlightSpan] = []

    init(highlighter: any CodeHighlighting = PlainCodeHighlighter()) {
        self.highlighter = highlighter
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        configureNativeTextView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureNativeTextView() {
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        drawsBackground = false
        isHorizontallyResizable = true
        isVerticallyResizable = true
        textContainerInset = Self.containerInset(zoom: .default)
        textContainer?.lineFragmentPadding = 0
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextReplacementEnabled = false
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Code")
    }

    /// Replaces TextKit storage in place and restores the native selection. The
    /// surrounding `CodeTextView` is never recreated for a streamed revision.
    func apply(code: String, language: String?, context: AgentRenderContext) {
        let selection = selectedRange()
        self.language = language
        theme = context.appearance
        tokens = context.tokens
        pageZoom = context.pageZoom
        // Re-derived per apply, not per construction: this view is recycled, and
        // a container inset frozen at 100% would misalign every zoomed row.
        textContainerInset = Self.containerInset(zoom: pageZoom)
        let codeLength = (code as NSString).length
        appliedSpans = highlighter.spans(language: language, code: code).filter { span in
            let location = span.range.location
            let length = span.range.length
            return location >= 0
                && length >= 0
                && location <= codeLength
                && length <= codeLength - location
        }

        let fullRange = NSRange(location: 0, length: codeLength)
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.token(.bodyMono, zoom: pageZoom),
            .foregroundColor: tokens.primaryText.color.nsColor(for: theme),
        ]
        let attributed = NSMutableAttributedString(string: code, attributes: base)
        for span in appliedSpans where span.token == .plain {
            attributed.addAttribute(
                .foregroundColor,
                value: tokens.primaryText.color.nsColor(for: theme),
                range: span.range
            )
        }
        textStorage?.setAttributedString(attributed)
        textColor = tokens.primaryText.color.nsColor(for: theme)

        let location = min(selection.location, fullRange.length)
        let length = min(selection.length, fullRange.length - location)
        setSelectedRange(NSRange(location: location, length: length))
        setAccessibilityLabel(language.flatMap(Self.displayLanguage).map { "\($0) code" } ?? "Code")
    }

    func applyTheme(_ theme: TokenTheme) {
        let selection = selectedRange()
        self.theme = theme
        let color = tokens.primaryText.color.nsColor(for: theme)
        textColor = color
        if let storage = textStorage, storage.length > 0 {
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: storage.length))
        }
        setSelectedRange(selection)
    }

    /// Keeps the document at least viewport-sized while allowing either axis to
    /// exceed it and activate the enclosing scroller.
    func sizeDocument(toFit viewport: NSSize) {
        let measured = Self.measuredCodeSize(string, zoom: pageZoom)
        frame.size = NSSize(
            width: max(viewport.width, measured.width),
            height: max(viewport.height, measured.height)
        )
    }

    /// The text-container inset a code surface uses at `zoom`. Shared by the
    /// live view and `measuredCodeSize` so the measured box can never disagree
    /// with the painted one.
    static func containerInset(zoom: AgentPageZoom) -> NSSize {
        NSSize(width: CGFloat(zoom.scaled(Space.l)), height: CGFloat(zoom.scaled(Space.m)))
    }

    static func measuredCodeSize(_ code: String, zoom: AgentPageZoom = .default) -> NSSize {
        let font = NSFont.token(.bodyMono, zoom: zoom)
        let sample = code.isEmpty ? " " : code
        let rect = (sample as NSString).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let newlineCount = code.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
        let height = max(ceil(rect.height), CGFloat(newlineCount + 1) * lineHeight)
        let inset = containerInset(zoom: zoom)
        return NSSize(
            width: ceil(rect.width) + inset.width * 2,
            height: height + inset.height * 2
        )
    }

    func writeEntireCode(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private static func displayLanguage(_ language: String) -> String? {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
