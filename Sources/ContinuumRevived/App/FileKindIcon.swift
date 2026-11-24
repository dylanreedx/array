import Foundation

/// The SF Symbol for a file in a list, by what it is. Swift's bird belongs to Swift
/// files only: a markdown report and a PNG each read as what they are.
enum FileKindIcon {
    static func symbol(forPath path: String, isDirectory: Bool = false) -> String {
        if isDirectory { return "folder" }
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt", "rtf": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tiff", "bmp": return "photo"
        case "mp4", "mov", "m4v", "webm": return "film"
        case "mp3", "wav", "m4a", "aiff": return "waveform"
        case "html", "htm": return "globe"
        case "pdf": return "doc.richtext"
        case "xlsx", "xls", "csv", "tsv", "numbers": return "tablecells"
        case "zip", "gz", "tar", "dmg", "tgz": return "doc.zipper"
        case "json", "yml", "yaml", "toml", "plist": return "curlybraces"
        case "sh", "zsh", "bash": return "terminal"
        case "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "m", "cpp", "java", "kt", "css": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}
