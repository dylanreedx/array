import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Fast, dependency-free presentation highlighting for file tiles. This is not
/// a parser and intentionally makes no editing claims; its output is an
/// attributed snapshot that can later be replaced by Tree-sitter without
/// changing the tile contract.
@MainActor
enum CodeSyntaxHighlighter {
    static let maximumHighlightedUTF16Length = 350_000

    static func attributedString(
        _ source: String,
        language: FilePreview.SourceLanguage,
        in view: NSView
    ) -> NSAttributedString {
        let length = (source as NSString).length
        let output = NSMutableAttributedString(string: source, attributes: [
            .font: NSFont.token(.bodyMono),
            .foregroundColor: TextToken.textPrimary.color.nsColor(in: view)
        ])
        guard language != .plainText, length > 0 else { return output }

        let styledLength = min(length, maximumHighlightedUTF16Length)
        let styledRange = NSRange(location: 0, length: styledLength)
        var protected: [NSRange] = []

        func paint(_ pattern: String, color: NSColor, options: NSRegularExpression.Options = []) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in expression.matches(in: source, range: styledRange) {
                output.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        func paintProtected(_ pattern: String, color: NSColor, options: NSRegularExpression.Options = []) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in expression.matches(in: source, range: styledRange) {
                protected.append(match.range)
                output.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        func paintCode(_ pattern: String, color: NSColor, options: NSRegularExpression.Options = []) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in expression.matches(in: source, range: styledRange)
                where !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                output.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        let comment = TextToken.textSecondary.color.nsColor(in: view)
        let keyword = AccentToken.accentInput.color.nsColor(in: view)
        let string = AccentToken.accentDone.color.nsColor(in: view)
        let number = AccentToken.accentWorking.color.nsColor(in: view)
        let declaration = AccentToken.accentApproval.color.nsColor(in: view)

        if language == .html {
            paintProtected(#"<!--[\s\S]*?-->"#, color: comment)
            paintProtected(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: string)
            paint(#"</?[A-Za-z][A-Za-z0-9:-]*"#, color: keyword)
            paint(#"\b[A-Za-z_:][-A-Za-z0-9_:.]*(?=\s*=)"#, color: declaration)
            return output
        }

        if language == .css {
            paintProtected(#"/\*[\s\S]*?\*/"#, color: comment)
            paintProtected(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: string)
            paintCode(#"(^|[;}])\s*[.#]?[A-Za-z_-][A-Za-z0-9_ -]*(?=\s*\{)"#, color: keyword, options: [.anchorsMatchLines])
            paintCode(#"\b[-A-Za-z]+(?=\s*:)"#, color: declaration)
            paintCode(#"(?<![A-Za-z])(?:\d+(?:\.\d+)?)(?:px|rem|em|vh|vw|%|s|ms)?\b"#, color: number)
            return output
        }

        if language == .json {
            paintProtected(#"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#, color: declaration)
            paintProtected(#"\"(?:\\.|[^\"\\])*\""#, color: string)
            paintCode(#"\b(?:true|false|null)\b"#, color: keyword)
            paintCode(#"(?<![A-Za-z_])-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, color: number)
            return output
        }

        let hashComments = language == .python || language == .shell
        if hashComments {
            paintProtected(#"#[^\n]*"#, color: comment)
        } else {
            paintProtected(#"//[^\n]*|/\*[\s\S]*?\*/"#, color: comment)
        }
        let stringPattern = language == .python
            ? #"(?s:\"\"\".*?\"\"\"|'''.*?''')|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#
            : #"`(?:\\.|[^`\\])*`|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#
        paintProtected(stringPattern, color: string)

        let words = keywords(for: language)
        if !words.isEmpty {
            paintCode(#"\b(?:"# + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")\b"#, color: keyword)
        }
        paintCode(#"\b(?:class|struct|enum|protocol|interface|trait|type|func|function|def)\s+([A-Za-z_][A-Za-z0-9_]*)"#, color: declaration)
        paintCode(#"(?<![A-Za-z_])(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#, color: number)
        return output
    }

    private static func keywords(for language: FilePreview.SourceLanguage) -> [String] {
        switch language {
        case .javascript, .typescript:
            return ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "while", "yield", "interface", "type", "implements", "namespace", "private", "protected", "public", "readonly"]
        case .go:
            return ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"]
        case .rust:
            return ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
        case .c, .csharp:
            return ["auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "false", "float", "for", "if", "int", "interface", "long", "namespace", "new", "null", "private", "protected", "public", "return", "short", "signed", "static", "string", "struct", "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong", "union", "unsigned", "using", "virtual", "void", "volatile", "while"]
        case .python:
            return ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case .swift:
            return ["actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "open", "operator", "private", "protocol", "public", "repeat", "return", "self", "Self", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"]
        case .shell:
            return ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "readonly", "return", "then", "until", "while"]
        case .html, .css, .json, .plainText: return []
        }
    }
}
