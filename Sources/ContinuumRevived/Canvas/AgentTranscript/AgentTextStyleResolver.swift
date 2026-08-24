import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Resolves semantic inline meaning into AppKit attributes. The semantic runs stay
/// untouched, so changing `theme` only rebuilds presentation and never reparses
/// provider text.
@MainActor
enum AgentTextStyleResolver {
    struct LinkRange: Equatable {
        let range: NSRange
        let destination: String
        let title: String?
        let disposition: AgentLinkDisposition
    }

    struct Result {
        let attributedString: NSAttributedString
        let links: [LinkRange]
        let markdown: String
    }

    private struct Marks {
        var emphasis = false
        var strong = false
        var code = false
    }


    static func attributedString(
        for runs: [AgentInline],
        theme: TokenTheme,
        tokens: AgentRenderTokens = .transcript,
        textRole: TextRole = .body,
        style: AgentProseTextStyle = .plain
    ) -> NSAttributedString {
        resolve(runs, theme: theme, tokens: tokens, textRole: textRole, style: style).attributedString
    }

    /// Serializes exactly the selected visible UTF-16 range while retaining any
    /// semantic wrappers that intersect it. This keeps partial native selections
    /// useful to Markdown-aware paste destinations instead of degrading them to
    /// plain text.
    static func markdown(for runs: [AgentInline], selectedRange: NSRange) -> String {
        guard selectedRange.length > 0 else { return "" }
        var location = 0
        return selectedMarkdown(runs, selection: selectedRange, location: &location)
    }

    static func resolve(
        _ runs: [AgentInline],
        theme: TokenTheme,
        tokens: AgentRenderTokens = .transcript,
        textRole: TextRole = .body,
        style: AgentProseTextStyle = .plain
    ) -> Result {
        let output = NSMutableAttributedString()
        var links: [LinkRange] = []
        var markdown = ""
        append(runs, marks: Marks(), theme: theme, tokens: tokens, textRole: textRole, style: style,
               output: output, links: &links, markdown: &markdown)
        // Applied once over the finished string rather than per run: a paragraph
        // style is a property of the paragraph, and setting it per appended run
        // would let a row with mixed emphasis wrap differently from a plain one.
        if let paragraphStyle = style.paragraphStyle, output.length > 0 {
            output.addAttribute(
                .paragraphStyle, value: paragraphStyle,
                range: NSRange(location: 0, length: output.length))
        }
        return Result(attributedString: NSAttributedString(attributedString: output), links: links, markdown: markdown)
    }

    private static func append(
        _ runs: [AgentInline],
        marks: Marks,
        theme: TokenTheme,
        tokens: AgentRenderTokens,
        textRole: TextRole,
        style: AgentProseTextStyle,
        output: NSMutableAttributedString,
        links: inout [LinkRange],
        markdown: inout String
    ) {
        for run in runs {
            switch run {
            case let .text(text):
                appendText(text, marks: marks, theme: theme, tokens: tokens, textRole: textRole, style: style, output: output)
                markdown += escapeMarkdown(text)
            case let .code(text):
                var nested = marks
                nested.code = true
                appendText(text, marks: nested, theme: theme, tokens: tokens, textRole: textRole, style: style, output: output)
                markdown += "`" + text.replacingOccurrences(of: "`", with: "\\`") + "`"
            case let .emphasis(children):
                var nested = marks
                nested.emphasis = true
                markdown += "*"
                append(children, marks: nested, theme: theme, tokens: tokens, textRole: textRole, style: style,
                       output: output, links: &links, markdown: &markdown)
                markdown += "*"
            case let .strong(children):
                var nested = marks
                nested.strong = true
                markdown += "**"
                append(children, marks: nested, theme: theme, tokens: tokens, textRole: textRole, style: style,
                       output: output, links: &links, markdown: &markdown)
                markdown += "**"
            case let .link(destination, title, children):
                let start = output.length
                var labelMarkdown = ""
                append(children, marks: marks, theme: theme, tokens: tokens, textRole: textRole, style: style,
                       output: output, links: &links, markdown: &labelMarkdown)
                let range = NSRange(location: start, length: output.length - start)
                let disposition = AgentLinkPolicy.disposition(for: destination)
                if range.length > 0 {
                    output.addAttributes([
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .agentLinkDestination: destination
                    ], range: range)
                    if disposition == .openExternally || disposition == .openInternally ||
                        disposition == .openLocalFile {
                        output.addAttribute(.link, value: destination, range: range)
                    }
                    links.append(LinkRange(range: range, destination: destination, title: title,
                                           disposition: disposition))
                }
                markdown += "[\(labelMarkdown)](\(destination)"
                if let title { markdown += " \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\"" }
                markdown += ")"
            case .softBreak:
                appendText(" ", marks: marks, theme: theme, tokens: tokens, textRole: textRole, style: style, output: output)
                markdown += "\n"
            case .hardBreak:
                appendText("\n", marks: marks, theme: theme, tokens: tokens, textRole: textRole, style: style, output: output)
                markdown += "  \n"
            }
        }
    }

    private static func selectedMarkdown(
        _ runs: [AgentInline],
        selection: NSRange,
        location: inout Int
    ) -> String {
        var markdown = ""
        for run in runs {
            switch run {
            case let .text(text):
                markdown += selectedText(text, selection: selection, location: &location, escape: true)
            case let .code(text):
                let selected = selectedText(text, selection: selection, location: &location, escape: false)
                if !selected.isEmpty {
                    markdown += "`" + selected.replacingOccurrences(of: "`", with: "\\`") + "`"
                }
            case let .emphasis(children):
                let selected = selectedMarkdown(children, selection: selection, location: &location)
                if !selected.isEmpty { markdown += "*\(selected)*" }
            case let .strong(children):
                let selected = selectedMarkdown(children, selection: selection, location: &location)
                if !selected.isEmpty { markdown += "**\(selected)**" }
            case let .link(destination, title, children):
                let selected = selectedMarkdown(children, selection: selection, location: &location)
                if !selected.isEmpty {
                    markdown += "[\(selected)](\(destination)"
                    if let title {
                        markdown += " \"\(title.replacingOccurrences(of: "\"", with: "\\\""))\""
                    }
                    markdown += ")"
                }
            case .softBreak:
                if NSLocationInRange(location, selection) { markdown += "\n" }
                location += 1 // A soft break is rendered as one space.
            case .hardBreak:
                if NSLocationInRange(location, selection) { markdown += "  \n" }
                location += 1
            }
        }
        return markdown
    }

    private static func selectedText(
        _ text: String,
        selection: NSRange,
        location: inout Int,
        escape: Bool
    ) -> String {
        let value = text as NSString
        let runRange = NSRange(location: location, length: value.length)
        location += value.length
        let intersection = NSIntersectionRange(runRange, selection)
        guard intersection.length > 0 else { return "" }
        let localRange = NSRange(location: intersection.location - runRange.location, length: intersection.length)
        let selected = value.substring(with: localRange)
        return escape ? escapeMarkdown(selected) : selected
    }

    private static func appendText(
        _ text: String,
        marks: Marks,
        theme: TokenTheme,
        tokens: AgentRenderTokens,
        textRole: TextRole,
        style: AgentProseTextStyle,
        output: NSMutableAttributedString
    ) {
        var font = NSFont.token(marks.code ? .bodyMono : textRole)
        var traits: NSFontTraitMask = []
        if marks.strong || style.bold { traits.insert(.boldFontMask) }
        if marks.emphasis { traits.insert(.italicFontMask) }
        if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: (style.secondary ? tokens.secondaryText : tokens.primaryText)
                .color.nsColor(for: theme)
        ]
        if marks.code {
            attributes[.backgroundColor] = tokens.codeSurface.color.nsColor(for: theme)
        }
        output.append(NSAttributedString(string: text, attributes: attributes))
    }

    private static func escapeMarkdown(_ text: String) -> String {
        var escaped = text
        for character in ["\\", "`", "*", "_", "[", "]"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\" + character)
        }
        return escaped
    }
}

extension NSAttributedString.Key {
    /// Metadata for display-only as well as activatable links. Unlike `.link`,
    /// this key does not grant activation behavior.
    static let agentLinkDestination = NSAttributedString.Key("continuum.agentLinkDestination")
}

/// Presentation applied to a whole prose row, alongside its `TextRole`.
///
/// `.plans/45` T4/T5. Two of this milestone's defects need something the resolver
/// could not express. The heading ladder needs weight and colour to vary per
/// level, because `Typography` offers only three usable sizes and
/// `minimumLadderStep` is itself gated, so six distinct SIZES are not buildable.
/// Hanging indents need a paragraph style, and `appendText` previously set only
/// `.font`, `.foregroundColor` and `.backgroundColor` — no transcript text ever
/// carried a `.paragraphStyle` at all.
///
/// It is one value rather than three parameters so that the measurement path
/// cannot drift from the paint path: both take the same struct, so an indent
/// that changes wrapping cannot be applied without also changing the height.
struct AgentProseTextStyle: Equatable {
    var bold = false
    var secondary = false
    /// Indent for every line after the first. With `firstLineHeadIndent` left at
    /// the marker's own position, this is what makes a wrapped bullet line up
    /// under the text instead of under the bullet.
    var headIndent: CGFloat = 0
    var firstLineHeadIndent: CGFloat = 0

    static let plain = AgentProseTextStyle()

    var isPlain: Bool { self == .plain }

    var paragraphStyle: NSParagraphStyle? {
        guard headIndent > 0 || firstLineHeadIndent > 0 else { return nil }
        let style = NSMutableParagraphStyle()
        style.headIndent = headIndent
        style.firstLineHeadIndent = firstLineHeadIndent
        style.lineBreakMode = .byWordWrapping
        return style
    }
}
