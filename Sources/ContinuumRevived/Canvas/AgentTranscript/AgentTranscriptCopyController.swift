import AppKit
import ContinuumRevivedAgentContent

/// Converts semantic blocks for pasteboard use. Rendering and provider payloads
/// are intentionally not involved, so selection stays safe and deterministic.
struct AgentTranscriptCopyController {
    static func plainText(for blocks: [AgentBlock]) -> String {
        blocks.map(plainText(for:)).joined(separator: "\n\n")
    }

    static func markdown(for blocks: [AgentBlock]) -> String {
        blocks.map(markdown(for:)).joined(separator: "\n\n")
    }

    static func writeToPasteboard(blocks: [AgentBlock], pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(plainText(for: blocks), forType: .string)
        pasteboard.setString(markdown(for: blocks), forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
    }

    private static func plainText(for block: AgentBlock) -> String {
        switch block.payload {
        case let .paragraph(inlines), let .heading(_, inlines):
            return plainText(inlines)
        case let .notice(notice):
            return plainText(notice.message)
        case let .fencedCode(code): return code.code
        case let .commandOutput(output): return output.text
        case let .error(error): return error.message
        case let .toolCall(tool): return [tool.name, tool.summary].compactMap { $0 }.joined(separator: " — ")
        case let .plan(plan):
            return ([plan.title] + planLines(plan.steps)).compactMap { $0 }.joined(separator: "\n")
        case let .diff(diff):
            let safe = ([diff.summary] + diff.files.map {
                "\($0.displayName) (+\($0.addedLineCount) −\($0.removedLineCount))"
            }).compactMap { $0 }
            return safe.isEmpty ? "File changes" : safe.joined(separator: "\n")
        case let .approval(request), let .question(request): return plainText(request.prompt)
        case .list, .listItem, .quote, .thematicBreak, .opaque: return block.children.map(plainText(for:)).joined(separator: "\n")
        }
    }

    private static func markdown(for block: AgentBlock) -> String {
        switch block.payload {
        case let .paragraph(inlines): return markdown(inlines)
        case let .notice(notice): return markdown(notice.message)
        case let .heading(level, inlines): return String(repeating: "#", count: Int(level)) + " " + markdown(inlines)
        case let .fencedCode(code):
            let newline = code.code.hasSuffix("\n") || code.code.hasSuffix("\r") ? "" : "\n"
            return "```\(code.language ?? "")\n\(code.code)\(newline)```"
        case let .quote: return block.children.map { "> " + markdown(for: $0) }.joined(separator: "\n")
        case let .list(list): return block.children.enumerated().map { list.ordered ? "\($0 + 1). \(markdown(for: $1))" : "- \(markdown(for: $1))" }.joined(separator: "\n")
        case .listItem: return block.children.map(markdown(for:)).joined(separator: "\n")
        case .thematicBreak: return "---"
        default: return plainText(for: block)
        }
    }

    private static func plainText(_ inlines: [AgentInline]) -> String {
        inlines.map { inline in
            switch inline {
            case let .text(value), let .code(value): return value
            case let .emphasis(children), let .strong(children), let .link(_, _, children): return plainText(children)
            case .softBreak: return " "
            case .hardBreak: return "\n"
            }
        }.joined()
    }

    private static func markdown(_ inlines: [AgentInline]) -> String {
        inlines.map { inline in
            switch inline {
            case let .text(value): return escapeMarkdown(value)
            case let .code(value): return "`\(value.replacingOccurrences(of: "`", with: "\\`"))`"
            case let .emphasis(children): return "*\(markdown(children))*"
            case let .strong(children): return "**\(markdown(children))**"
            case let .link(destination, title, children):
                let suffix = title.map { " \"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? ""
                return "[\(markdown(children))](\(destination)\(suffix))"
            case .softBreak: return "\n"
            case .hardBreak: return "  \n"
            }
        }.joined()
    }

    private static func planLines(_ steps: [AgentPlanStep], depth: Int = 0) -> [String] {
        steps.flatMap { step in
            [String(repeating: "  ", count: depth) + step.title]
                + planLines(step.children, depth: depth + 1)
        }
    }

    private static func escapeMarkdown(_ text: String) -> String {
        var escaped = text
        for character in ["\\", "`", "*", "_", "[", "]"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\" + character)
        }
        return escaped
    }
}
