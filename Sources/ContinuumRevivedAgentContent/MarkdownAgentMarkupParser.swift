import Foundation
import Markdown

/// The sole production adapter from swift-markdown's AST into AgentContent.
/// swift-markdown nodes never escape this platform-neutral semantic boundary.
public struct MarkdownAgentMarkupParser: AgentMarkupParsing {
    private static let maximumInlineDepth = 64
    private static let maximumBlockDepth = 32

    public init() {}

    public func parse(
        _ source: String,
        entryID: AgentNodeID,
        previous: [AgentBlock]
    ) -> AgentMarkupParse {
        guard !source.isEmpty else { return AgentMarkupParse(blocks: []) }

        let document = Document(parsing: source)
        var diagnostics: [AgentMarkupDiagnostic] = []
        let blocks = convertBlocks(
            document,
            source: source,
            scopeID: entryID,
            previous: previous,
            depth: 0,
            diagnostics: &diagnostics
        )
        return AgentMarkupParse(blocks: blocks, diagnostics: diagnostics)
    }

    private func convertBlocks(
        _ parent: Markup,
        source: String,
        scopeID: AgentNodeID,
        previous: [AgentBlock],
        depth: Int,
        diagnostics: inout [AgentMarkupDiagnostic]
    ) -> [AgentBlock] {
        var blocks: [AgentBlock] = []
        var occurrences: [String: Int] = [:]

        for child in parent.children {
            let kind = blockKind(for: child)
            let fingerprint = sourceFingerprint(literalSource(for: child, in: source) ?? kind.rawValue)
            let occurrenceKey = "\(kind.rawValue).\(fingerprint)"
            let occurrence = occurrences[occurrenceKey, default: 0]
            occurrences[occurrenceKey] = occurrence + 1
            let id = blockID(
                entryID: scopeID,
                stableKey: "markdown.\(kind.rawValue).\(fingerprint).\(occurrence)"
            )
            blocks.append(convertBlock(
                child,
                kind: kind,
                id: id,
                source: source,
                previous: nil,
                depth: depth,
                diagnostics: &diagnostics
            ))
        }
        return reconcileIdentities(blocks, with: previous)
    }

    private func reconcileIdentities(_ current: [AgentBlock], with previous: [AgentBlock]) -> [AgentBlock] {
        var exactMatches: [Int: Int] = [:]
        var reservedPrevious: Set<Int> = []

        for currentIndex in current.indices {
            if let previousIndex = previous.indices.first(where: {
                !reservedPrevious.contains($0) && semanticallyEqual(current[currentIndex], previous[$0])
            }) {
                exactMatches[currentIndex] = previousIndex
                reservedPrevious.insert(previousIndex)
            }
        }

        return current.indices.map { currentIndex in
            if let previousIndex = exactMatches[currentIndex] {
                return adoptingIdentity(current[currentIndex], from: previous[previousIndex])
            }
            if previous.indices.contains(currentIndex),
               !reservedPrevious.contains(currentIndex),
               previous[currentIndex].kind == current[currentIndex].kind {
                reservedPrevious.insert(currentIndex)
                return adoptingIdentity(current[currentIndex], from: previous[currentIndex])
            }
            if currentIndex == current.startIndex,
               let previousIndex = previous.indices.first(where: {
                   !reservedPrevious.contains($0) && previous[$0].kind == current[currentIndex].kind
               }) {
                reservedPrevious.insert(previousIndex)
                return adoptingIdentity(current[currentIndex], from: previous[previousIndex])
            }
            return current[currentIndex]
        }
    }

    private func semanticallyEqual(_ lhs: AgentBlock, _ rhs: AgentBlock) -> Bool {
        lhs.kind == rhs.kind && lhs.payload == rhs.payload &&
            lhs.children.count == rhs.children.count &&
            zip(lhs.children, rhs.children).allSatisfy { semanticallyEqual($0.0, $0.1) }
    }

    private func adoptingIdentity(_ block: AgentBlock, from previous: AgentBlock) -> AgentBlock {
        AgentBlock(
            id: previous.id,
            revision: block.revision,
            kind: block.kind,
            sourceRange: block.sourceRange,
            payload: block.payload,
            children: reconcileIdentities(block.children, with: previous.children)
        )
    }

    private func blockKind(for markup: Markup) -> AgentBlockKind {
        switch markup {
        case is Paragraph: return .paragraph
        case is Heading: return .heading
        case is OrderedList, is UnorderedList: return .list
        case is ListItem: return .listItem
        case is BlockQuote: return .quote
        case is ThematicBreak: return .thematicBreak
        default: return .unknown
        }
    }

    private func convertBlock(
        _ markup: Markup,
        kind: AgentBlockKind,
        id: AgentNodeID,
        source: String,
        previous: AgentBlock?,
        depth: Int,
        diagnostics: inout [AgentMarkupDiagnostic]
    ) -> AgentBlock {
        if depth >= Self.maximumBlockDepth, markup.childCount > 0 {
            diagnostics.append(.init(severity: .warning, code: "markdown.block-nesting-limit"))
            return opaqueBlock(
                markup,
                id: id,
                source: source,
                debugLabel: "markdown.block-nesting-limit"
            )
        }

        switch markup {
        case let paragraph as Paragraph:
            return AgentBlock(id: id, kind: .paragraph, payload: .paragraph(convertInlineChildren(
                paragraph, source: source, depth: 0, diagnostics: &diagnostics
            )))
        case let heading as Heading:
            let level = UInt8(min(max(heading.level, 1), 6))
            return AgentBlock(id: id, kind: .heading, payload: .heading(
                level: level,
                content: convertInlineChildren(heading, source: source, depth: 0, diagnostics: &diagnostics)
            ))
        case let ordered as OrderedList:
            return AgentBlock(
                id: id,
                kind: .list,
                payload: .list(.init(ordered: true, start: Int(exactly: ordered.startIndex) ?? Int.max)),
                children: convertBlocks(
                    ordered,
                    source: source,
                    scopeID: id,
                    previous: previous?.children ?? [],
                    depth: depth + 1,
                    diagnostics: &diagnostics
                )
            )
        case let unordered as UnorderedList:
            return AgentBlock(
                id: id,
                kind: .list,
                payload: .list(.init(ordered: false)),
                children: convertBlocks(
                    unordered,
                    source: source,
                    scopeID: id,
                    previous: previous?.children ?? [],
                    depth: depth + 1,
                    diagnostics: &diagnostics
                )
            )
        case let item as ListItem:
            // Task markers remain ordinary readable text. swift-markdown lifts
            // them out of the paragraph into checkbox metadata, so put that
            // syntax back without turning it into an approval or action.
            var children = convertBlocks(
                item,
                source: source,
                scopeID: id,
                previous: previous?.children ?? [],
                depth: depth + 1,
                diagnostics: &diagnostics
            )
            if let checkbox = item.checkbox {
                let marker: String
                switch checkbox {
                case .checked: marker = "[x] "
                case .unchecked: marker = "[ ] "
                }
                if let paragraphIndex = children.firstIndex(where: { $0.kind == .paragraph }),
                   case let .paragraph(inlines) = children[paragraphIndex].payload {
                    var marked = inlines
                    if case let .text(text)? = marked.first {
                        marked[0] = .text(marker + text)
                    } else {
                        marked.insert(.text(marker), at: 0)
                    }
                    children[paragraphIndex].payload = .paragraph(marked)
                }
            }
            return AgentBlock(id: id, kind: .listItem, payload: .listItem, children: children)
        case let quote as BlockQuote:
            return AgentBlock(
                id: id,
                kind: .quote,
                payload: .quote,
                children: convertBlocks(
                    quote,
                    source: source,
                    scopeID: id,
                    previous: previous?.children ?? [],
                    depth: depth + 1,
                    diagnostics: &diagnostics
                )
            )
        case is ThematicBreak:
            return AgentBlock(id: id, kind: .thematicBreak, payload: .thematicBreak)
        default:
            diagnostics.append(.init(severity: .warning, code: "markdown.unsupported-structure"))
            return opaqueBlock(
                markup,
                id: id,
                source: source,
                debugLabel: "markdown.unsupported-structure"
            )
        }
    }

    private func opaqueBlock(
        _ markup: Markup,
        id: AgentNodeID,
        source: String,
        debugLabel: String
    ) -> AgentBlock {
        AgentBlock(
            id: id,
            kind: .unknown,
            payload: .opaque(.init(
                debugLabel: debugLabel,
                value: .string(literalSource(for: markup, in: source)
                    .map { $0.trimmingCharacters(in: .newlines) } ?? "")
            ))
        )
    }

    private func convertInlineChildren(
        _ parent: Markup,
        source: String,
        depth: Int,
        diagnostics: inout [AgentMarkupDiagnostic]
    ) -> [AgentInline] {
        var result: [AgentInline] = []
        for child in parent.children {
            let converted = convertInline(child, source: source, depth: depth, diagnostics: &diagnostics)
            appendMergingText(converted, to: &result)
        }
        return result
    }

    private func convertInline(
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
            return .emphasis(convertInlineChildren(markup, source: source, depth: depth + 1, diagnostics: &diagnostics))
        }
        if depth < Self.maximumInlineDepth, markup is Strong {
            return .strong(convertInlineChildren(markup, source: source, depth: depth + 1, diagnostics: &diagnostics))
        }

        let exceededDepth = (markup is Emphasis || markup is Strong) && depth >= Self.maximumInlineDepth
        diagnostics.append(.init(
            severity: .warning,
            code: exceededDepth ? "markdown.inline-nesting-limit" : "markdown.unsupported-inline"
        ))
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

    /// swift-markdown columns are one-based UTF-8 byte offsets.
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

    private func sourceFingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private func blockID(entryID: AgentNodeID, stableKey: String) -> AgentNodeID {
        if let child = entryID.childID(stableKey: stableKey) { return child }

        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in entryID.rawValue.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x9e3779b185ebca87
        }
        let digest = String(format: "%016llx%016llx", first, second)
        return AgentNodeID(rawValue: "markdown-entry:\(digest)/\(stableKey)")!
    }
}
