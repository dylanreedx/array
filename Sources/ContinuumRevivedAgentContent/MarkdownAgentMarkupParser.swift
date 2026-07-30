import Foundation
import Markdown

/// The sole production adapter from swift-markdown's AST into AgentContent.
/// Block-family conversion remains deliberately narrow here, while paragraph
/// contents are translated into the platform-neutral inline vocabulary.
public struct MarkdownAgentMarkupParser: AgentMarkupParsing {
    private static let maximumInlineDepth = 64

    public init() {}

    public func parse(
        _ source: String,
        entryID: AgentNodeID,
        previous: [AgentBlock]
    ) -> AgentMarkupParse {
        guard !source.isEmpty else { return AgentMarkupParse(blocks: []) }

        let document = Document(parsing: source)
        var diagnostics: [AgentMarkupDiagnostic] = []
        var blocks: [AgentBlock] = []
        var occurrences: [AgentBlockKind: Int] = [:]

        for child in document.children {
            let kind: AgentBlockKind
            let payload: AgentBlockPayload
            switch child {
            case let paragraph as Paragraph:
                kind = .paragraph
                payload = .paragraph(convertChildren(
                    paragraph, source: source, depth: 0, diagnostics: &diagnostics
                ))
            case let heading as Heading:
                kind = .heading
                // swift-markdown accepts levels beyond HTML's six headings;
                // AgentContent keeps that boundary explicit for renderers.
                let level = UInt8(min(max(heading.level, 1), 6))
                payload = .heading(level: level, content: convertChildren(
                    heading, source: source, depth: 0, diagnostics: &diagnostics
                ))
            default:
                kind = .unknown
                payload = .opaque(.init(
                    debugLabel: "markdown.unsupported-structure",
                    // Preserve only this child, not the complete document. A
                    // mixed document must keep each semantic block boundary
                    // intact for rendering and plain-text copy.
                    value: .string(literalSource(for: child, in: source)
                        .map { $0.trimmingCharacters(in: .newlines) } ?? "")
                ))
                diagnostics.append(.init(severity: .warning, code: "markdown.unsupported-structure"))
            }

            let occurrence = occurrences[kind, default: 0]
            occurrences[kind] = occurrence + 1
            let positionalID: AgentNodeID? = blocks.count < previous.count && previous[blocks.count].kind == kind
                ? previous[blocks.count].id
                : nil
            let legacyID: AgentNodeID? = blocks.isEmpty
                ? previous.first(where: { $0.kind == kind })?.id
                : nil
            let id = positionalID
                ?? legacyID
                ?? blockID(entryID: entryID, stableKey: "markdown.\(kind.rawValue).\(occurrence)")
            blocks.append(AgentBlock(id: id, kind: kind, payload: payload))
        }

        return AgentMarkupParse(blocks: blocks, diagnostics: diagnostics)
    }

    private func convertChildren(
        _ parent: Markup,
        source: String,
        depth: Int,
        diagnostics: inout [AgentMarkupDiagnostic]
    ) -> [AgentInline] {
        var result: [AgentInline] = []
        for child in parent.children {
            let converted = convert(child, source: source, depth: depth, diagnostics: &diagnostics)
            appendMergingText(converted, to: &result)
        }
        return result
    }

    private func convert(
        _ markup: Markup,
        source: String,
        depth: Int,
        diagnostics: inout [AgentMarkupDiagnostic]
    ) -> AgentInline {
        if let text = markup as? Text { return .text(text.string) }
        if let code = markup as? InlineCode { return .code(code.code) }
        if markup is SoftBreak { return .softBreak }
        if markup is LineBreak { return .hardBreak }

        if depth < Self.maximumInlineDepth, markup is Emphasis {
            return .emphasis(convertChildren(markup, source: source, depth: depth + 1, diagnostics: &diagnostics))
        }
        if depth < Self.maximumInlineDepth, markup is Strong {
            return .strong(convertChildren(markup, source: source, depth: depth + 1, diagnostics: &diagnostics))
        }

        let exceededDepth = (markup is Emphasis || markup is Strong) && depth >= Self.maximumInlineDepth
        diagnostics.append(.init(
            severity: .warning,
            code: exceededDepth ? "markdown.inline-nesting-limit" : "markdown.unsupported-inline"
        ))
        // Parsed inline nodes carry exact UTF-8 source ranges. Keeping the
        // original spelling here is important: flattening an image, link, HTML
        // node, or over-deep mark through `plainText` would silently discard
        // delimiters or destinations before their dedicated parser tickets.
        return .text(literalSource(for: markup, in: source) ?? source)
    }

    private func appendMergingText(_ inline: AgentInline, to result: inout [AgentInline]) {
        if case let .text(value) = inline,
           case let .text(previous)? = result.last {
            result[result.count - 1] = .text(previous + value)
        } else {
            result.append(inline)
        }
    }

    private func literalSource(for markup: Markup, in source: String) -> String? {
        guard let range = markup.range,
              let lower = sourceIndex(line: range.lowerBound.line, column: range.lowerBound.column, in: source),
              let upper = sourceIndex(line: range.upperBound.line, column: range.upperBound.column, in: source),
              lower <= upper
        else { return nil }
        return String(source[lower..<upper])
    }

    /// swift-markdown columns are one-based UTF-8 byte offsets, including for
    /// non-ASCII source. Convert without treating a byte offset as a Character
    /// offset, which would corrupt an unsupported node following Unicode text.
    private func sourceIndex(line targetLine: Int, column: Int, in source: String) -> String.Index? {
        guard targetLine >= 1, column >= 1 else { return nil }
        var line = 1
        var lineStart = source.utf8.startIndex
        var cursor = lineStart
        while line < targetLine, cursor < source.utf8.endIndex {
            if source.utf8[cursor] == 0x0A {
                line += 1
                lineStart = source.utf8.index(after: cursor)
            }
            cursor = source.utf8.index(after: cursor)
        }
        guard line == targetLine,
              let byteIndex = source.utf8.index(lineStart, offsetBy: column - 1, limitedBy: source.utf8.endIndex),
              let index = String.Index(byteIndex, within: source)
        else { return nil }
        return index
    }

    /// `AgentNodeID` permits provider IDs longer than its child-scope bound.
    /// Keep the ordinary readable child ID, but compact an unusually long scope
    /// to a deterministic parser-owned ID rather than dropping valid source.
    private func blockID(entryID: AgentNodeID, stableKey: String) -> AgentNodeID {
        if let child = entryID.childID(stableKey: stableKey) { return child }

        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in entryID.rawValue.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x9e3779b185ebca87
        }
        let digest = String(format: "%016llx%016llx", first, second)
        // Both inputs are fixed/bounded here, so construction cannot fail.
        return AgentNodeID(rawValue: "markdown-entry:\(digest)/\(stableKey)")!
    }
}
