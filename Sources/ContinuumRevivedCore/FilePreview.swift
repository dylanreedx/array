import Foundation

public enum FilePreview: Equatable, Sendable {
    public static let maxReadBytes = 1_024 * 1_024

    case text(String)
    case unavailable(String)

    /// How a successfully loaded file should be presented. Core classifies; it
    /// never parses or styles Markdown.
    public enum Presentation: Equatable, Sendable {
        case sourceText
        case markdown
    }

    /// Lightweight language identity for code presentation. This deliberately
    /// stops short of an editor/LSP contract: file tiles need stable visual
    /// grammar now, while parsing, diagnostics, and editing can evolve
    /// independently later.
    public enum SourceLanguage: String, CaseIterable, Equatable, Sendable {
        case javascript = "JavaScript"
        case typescript = "TypeScript"
        case html = "HTML"
        case css = "CSS"
        case go = "Go"
        case rust = "Rust"
        case c = "C / C++"
        case csharp = "C#"
        case python = "Python"
        case swift = "Swift"
        case json = "JSON"
        case shell = "Shell"
        case plainText = "Text"
    }

    public static func sourceLanguage(forPath path: String) -> SourceLanguage {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "html", "htm": return .html
        case "css", "scss", "sass", "less": return .css
        case "go": return .go
        case "rs": return .rust
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hxx": return .c
        case "cs": return .csharp
        case "py", "pyw": return .python
        case "swift": return .swift
        case "json", "jsonc": return .json
        case "sh", "bash", "zsh", "fish": return .shell
        default:
            if ["dockerfile", "makefile", "gemfile", "rakefile"].contains(name) { return .shell }
            return .plainText
        }
    }

    /// Markdown is decided by the real path extension, case-insensitively. A
    /// filename that merely CONTAINS `.md` (`notes.md.txt`, `mdfile`) is source.
    public static func presentation(forPath path: String) -> Presentation {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ext == "md" || ext == "markdown" ? .markdown : .sourceText
    }

    public static func load(path: String) -> FilePreview {
        load(path: path) { url in
            try Data(contentsOf: url)
        }
    }

    package static func load(path: String, readData: (URL) throws -> Data) -> FilePreview {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .unavailable("File not found")
        }

        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
           values.isRegularFile == false {
            return .unavailable("File not found")
        }

        if let byteCount = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value,
           byteCount > Int64(maxReadBytes) {
            return .unavailable("File too large to preview (> 1 MB)")
        }

        do {
            let data = try readData(url)
            guard data.count <= maxReadBytes else {
                return .unavailable("File too large to preview (> 1 MB)")
            }
            guard !hasNonUTF8BOM(data), !containsNullByte(data) else {
                return .unavailable("Binary file -- open in preferred editor")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .unavailable("Binary file -- open in preferred editor")
            }
            return .text(text)
        } catch {
            return .unavailable("File not found")
        }
    }

    private static func hasNonUTF8BOM(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return false }
        return bytes.starts(with: [0xFE, 0xFF])
            || bytes.starts(with: [0xFF, 0xFE])
            || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF])
            || bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00])
    }

    private static func containsNullByte(_ data: Data) -> Bool {
        data.prefix(8 * 1_024).contains(0)
    }
}
