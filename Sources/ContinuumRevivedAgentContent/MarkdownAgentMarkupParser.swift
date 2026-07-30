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

        let sourceMap = SourceMap(source: source)
        let document = Document(parsing: sourceMap.normalized)
        var diagnostics: [AgentMarkupDiagnostic] = []
        let blocks = convertBlocks(
            document,
            source: source,
            sourceMap: sourceMap,
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
        sourceMap: SourceMap,
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
                sourceMap: sourceMap,
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
        case is CodeBlock: return .fencedCode
        default: return .unknown
        }
    }

    private func convertBlock(
        _ markup: Markup,
        kind: AgentBlockKind,
        id: AgentNodeID,
        source: String,
        sourceMap: SourceMap,
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
                    sourceMap: sourceMap,
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
                    sourceMap: sourceMap,
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
                sourceMap: sourceMap,
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
                    sourceMap: sourceMap,
                    scopeID: id,
                    previous: previous?.children ?? [],
                    depth: depth + 1,
                    diagnostics: &diagnostics
                )
            )
        case is ThematicBreak:
            return AgentBlock(id: id, kind: .thematicBreak, payload: .thematicBreak)
        case let codeBlock as CodeBlock:
            let conversion = codePayload(for: codeBlock, sourceMap: sourceMap)
            if conversion.diagnostic {
                diagnostics.append(.init(severity: .warning, code: "markdown.code-source-alignment"))
            }
            return AgentBlock(
                id: id,
                kind: .fencedCode,
                payload: .fencedCode(.init(
                    language: conversion.language,
                    code: conversion.code,
                    isComplete: conversion.isComplete
                ))
            )
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
        if let link = markup as? Link {
            return .link(
                destination: link.destination ?? "",
                title: link.title,
                children: convertInlineChildren(
                    link,
                    source: source,
                    depth: depth + 1,
                    diagnostics: &diagnostics
                )
            )
        }

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
        let map = SourceMap(source: source)
        guard let range = markup.range,
              let lower = sourceIndex(line: range.lowerBound.line, column: range.lowerBound.column, in: map),
              let upper = sourceIndex(line: range.upperBound.line, column: range.upperBound.column, in: map),
              lower <= upper
        else { return nil }
        return String(source[lower..<upper])
    }

    private func line(_ lines: [SourceLine], _ index: Int) -> SourceLine? {
        lines.indices.contains(index) ? lines[index] : nil
    }

    /// swift-markdown columns are one-based UTF-8 byte offsets.
    private func sourceIndex(line targetLine: Int, column: Int, in map: SourceMap) -> String.Index? {
        guard targetLine >= 1, column >= 1, let line = line(map.lines, targetLine - 1) else { return nil }
        let offset = column - 1
        guard offset <= line.contentByteRange.count else { return nil }
        return String.Index(map.source.utf8.index(map.source.utf8.startIndex, offsetBy: line.contentByteRange.lowerBound + offset), within: map.source)
    }

    private struct SourceLine {
        let text: String
        let ending: String
        let contentByteRange: Range<Int>
    }

    private struct SourceMap {
        let source: String
        let lines: [SourceLine]
        let normalized: String

        init(source: String) {
            self.source = source
            var lines: [SourceLine] = []
            var normalizedBytes: [UInt8] = []
            let bytes = Array(source.utf8)
            var start = 0
            var i = 0
            while i < bytes.count {
                let endingStart = i
                if bytes[i] == 0x0D || bytes[i] == 0x0A {
                    if bytes[i] == 0x0D && i + 1 < bytes.count && bytes[i + 1] == 0x0A { i += 2 } else { i += 1 }
                    let content = Array(bytes[start..<endingStart])
                    let ending = String(decoding: bytes[endingStart..<i], as: UTF8.self)
                    lines.append(SourceLine(text: String(decoding: content, as: UTF8.self), ending: ending, contentByteRange: start..<endingStart))
                    normalizedBytes.append(contentsOf: content); normalizedBytes.append(0x0A)
                    start = i
                } else { i += 1 }
            }
            let content = Array(bytes[start..<bytes.count])
            lines.append(SourceLine(text: String(decoding: content, as: UTF8.self), ending: "", contentByteRange: start..<bytes.count))
            normalizedBytes.append(contentsOf: content)
            self.lines = lines
            self.normalized = String(decoding: normalizedBytes, as: UTF8.self)
        }
    }

    private struct CodeConversion {
        let language: String?
        let code: String
        let isComplete: Bool
        let diagnostic: Bool
    }

    private func codePayload(for block: CodeBlock, sourceMap: SourceMap) -> CodeConversion {
        let language = block.language.flatMap { raw -> String? in
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
            return token.isEmpty || token.hasPrefix("{") ? nil : token.lowercased()
        }
        guard let range = block.range,
              let lower = line(sourceMap.lines, range.lowerBound.line - 1),
              line(sourceMap.lines, range.upperBound.line - 1) != nil
        else { return CodeConversion(language: language, code: block.code, isComplete: true, diagnostic: true) }

        // An empty cmark code string has no semantic content lines. Splitting it
        // with empty subsequences would invent one line and align the closer as
        // though it were body content.
        let codeLines: [String]
        if block.code.isEmpty {
            codeLines = []
        } else {
            let rawCodeLines = block.code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            codeLines = block.code.hasSuffix("\n") ? Array(rawCodeLines.dropLast()) : rawCodeLines
        }
        let lowerColumn = max(0, range.lowerBound.column - 1)
        let marker = lower.text.utf8.dropFirst(min(lowerColumn, lower.text.utf8.count)).first
        let fenced = marker == 0x60 || marker == 0x7E
        let spanCount = range.upperBound.line - range.lowerBound.line + 1
        let expectedCompleteSpan = codeLines.count + (fenced ? 2 : 0)
        let expectedIncompleteSpan = codeLines.count + (fenced ? 1 : 0)
        let complete = !fenced || spanCount == expectedCompleteSpan
        // The source range must describe exactly the semantic body plus its
        // structural fence lines (or the opening fence for an incomplete block).
        // Never attach endings from a guessed subset of a malformed range.
        let alignmentIsValid = fenced
            ? spanCount == expectedCompleteSpan || spanCount == expectedIncompleteSpan
            : spanCount == expectedCompleteSpan
        guard alignmentIsValid else {
            return CodeConversion(language: language, code: block.code, isComplete: complete, diagnostic: true)
        }
        let firstContent = range.lowerBound.line + (fenced ? 1 : 0)
        let selectedCount = codeLines.count
        guard firstContent + selectedCount - 1 <= range.upperBound.line || selectedCount == 0 else {
            return CodeConversion(language: language, code: block.code, isComplete: complete, diagnostic: true)
        }
        var output = ""
        for index in 0..<selectedCount {
            let lineNumber = firstContent + index
            guard let physical = line(sourceMap.lines, lineNumber - 1) else {
                return CodeConversion(language: language, code: block.code, isComplete: complete, diagnostic: true)
            }
            output += codeLines[index] + physical.ending
        }
        return CodeConversion(language: language, code: output, isComplete: complete, diagnostic: false)
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
