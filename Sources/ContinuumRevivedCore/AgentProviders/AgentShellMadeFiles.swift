import Foundation

/// The files a shell command made, so a turn's Changes card can show them.
///
/// Agents make most of their files through the shell — a heredoc, `cp`,
/// `screencapture`, `sips --out`, a script — and a shell call carries no file
/// facts at all, so none of those files reached the card. Measured on two days
/// of real sessions (2026-11-25): of 28 images and pages agents produced
/// outside temp folders, 26 came from the shell and none of them showed.
///
/// The rule, kept cheap on purpose (no tree scan, no watcher):
/// - Only paths the command NAMES are looked at: literal words with an
///   extension the strip can picture (image, pdf, page, markdown, code),
///   absolute, `~`-relative, or relative to the shell's directory or a literal
///   `cd` in the command. At most `maximumCandidates` stats per command.
/// - A named file that exists after the command and was BORN while it ran is
///   created (`.add`). One that existed and was MODIFIED while it ran is
///   rewritten (`.write`), kept only for kinds the strip pictures whatever the
///   action (image, pdf, page, markdown) — a `sed -i` on source is an edit the
///   card cannot picture, and it is not claimed.
/// - Temp folders and tool caches are scratch, never deliverables, and are
///   skipped.
///
/// The live stream and the session restore both call `detect`, with the call's
/// start and end instants, so a file reads the same both ways.
public enum AgentShellMadeFiles {
    public struct Made: Equatable, Sendable {
        public let url: URL
        public let action: AgentToolDetailObservation.FileAction
        /// Lines a created text file holds; nil for a picture or a rewrite.
        public let addedLines: UInt?

        public var fileChange: AgentToolDetailObservation.FileChange {
            .init(action: action, path: url.lastPathComponent, addedLines: addedLines)
        }
    }

    static let pictureExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "html", "htm", "svg"]
    static let documentExtensions: Set<String> = ["md", "markdown"]
    static let codeExtensions: Set<String> = ["swift", "ts", "py", "js", "json", "sh"]
    static let scratchComponents: Set<String> = [".git", ".build", ".swiftpm", "node_modules", "DerivedData", ".claude", ".codex"]
    static let maximumCandidates = 16
    /// A created file's lines are counted only below this size.
    static let maximumCountedBytes = 512 * 1024
    /// Birth and modification instants are compared with this much slack: the
    /// start is when the call was observed, a moment after it may have begun.
    static let slack: TimeInterval = 2

    /// The id of the file-change item that carries a shell call's made files.
    public static func itemID(forShellItem id: String) -> String { "\(id)#made-files" }

    public static func detect(
        command: String, workingDirectory: URL?, startedAt: Date, endedAt: Date,
        fileManager: FileManager = .default
    ) -> [Made] {
        let from = startedAt.addingTimeInterval(-slack)
        let to = max(endedAt, startedAt).addingTimeInterval(slack)
        var made: [Made] = []
        var seen = Set<String>()
        for url in candidates(command: command, workingDirectory: workingDirectory) {
            guard seen.insert(url.path).inserted,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            if let born = values.creationDate, born >= from, born <= to {
                var lines: UInt?
                if !pictureExtensions.contains(ext) || ext == "html" || ext == "htm" || ext == "svg",
                   let size = values.fileSize, size <= maximumCountedBytes,
                   let data = fileManager.contents(atPath: url.path) {
                    let newlines = data.reduce(into: UInt(0)) { if $1 == 0x0A { $0 += 1 } }
                    lines = newlines + (data.last.map { $0 == 0x0A ? 0 : 1 } ?? 0)
                }
                made.append(Made(url: url, action: .add, addedLines: lines))
            } else if let modified = values.contentModificationDate, modified >= from, modified <= to,
                      pictureExtensions.contains(ext) || documentExtensions.contains(ext) {
                made.append(Made(url: url, action: .write, addedLines: nil))
            }
        }
        return made
    }

    /// The literal file paths a command names that the strip could picture,
    /// resolved and in order, at most `maximumCandidates` of them.
    static func candidates(command: String, workingDirectory: URL?) -> [URL] {
        let separators = CharacterSet(charactersIn: " \t\n\r'\"`;|&()<>=,")
        let words = command.components(separatedBy: separators).filter { !$0.isEmpty }
        var bases: [URL] = workingDirectory.map { [$0] } ?? []
        var result: [URL] = []
        var previous = ""
        for raw in words {
            defer { previous = raw }
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: ":."))
            if previous == "cd", bases.count < 4, isLiteral(word) {
                if let directory = resolve(word, bases: bases.isEmpty ? [] : [bases[bases.count - 1]]).first {
                    bases.append(directory)
                }
                continue
            }
            guard isLiteral(word) else { continue }
            let ext = (word as NSString).pathExtension.lowercased()
            guard pictureExtensions.contains(ext) || documentExtensions.contains(ext) || codeExtensions.contains(ext)
            else { continue }
            for url in resolve(word, bases: bases) where !isScratch(url) {
                result.append(url)
                if result.count >= maximumCandidates { return result }
            }
        }
        return result
    }

    private static func isLiteral(_ word: String) -> Bool {
        !word.isEmpty && word.rangeOfCharacter(from: CharacterSet(charactersIn: "$*?{}[]\\")) == nil
            && !word.hasPrefix("-") && !word.contains("://")
    }

    private static func resolve(_ word: String, bases: [URL]) -> [URL] {
        let expanded = (word as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath { return [URL(fileURLWithPath: expanded).standardizedFileURL] }
        return bases.reversed().map { $0.appendingPathComponent(expanded).standardizedFileURL }
    }

    static func isScratch(_ url: URL) -> Bool {
        let path = url.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        for root in ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", temporary + "/"] where path.hasPrefix(root) {
            return true
        }
        return url.pathComponents.contains { scratchComponents.contains($0) }
    }
}
