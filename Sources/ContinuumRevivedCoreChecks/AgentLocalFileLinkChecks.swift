import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// `.plans/15-file-opening-markdown-preview.md` — the resolving half of an agent's
/// local-file link, plus the Core file-kind classification the file tile presents
/// from. Authored content may request resolution; it may not reach outside the
/// checkout its agent is working in.
func runAgentLocalFileLinkChecks() {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-local-file-link-\(UUID().uuidString)", isDirectory: true)
    let checkout = tempRoot.appendingPathComponent("checkout", isDirectory: true)
    // A sibling whose name starts with the checkout's name: a string-prefix
    // containment test would wrongly accept it.
    let sibling = tempRoot.appendingPathComponent("checkout-evil", isDirectory: true)
    defer { try? fileManager.removeItem(at: tempRoot) }

    do {
        try fileManager.createDirectory(at: checkout.appendingPathComponent("Sources", isDirectory: true),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("let x = 1\n".utf8).write(to: checkout.appendingPathComponent("Sources/App.swift"))
        try Data("space in name\n".utf8).write(to: checkout.appendingPathComponent("Sources/Two Words.swift"))
        try Data("secret\n".utf8).write(to: sibling.appendingPathComponent("secret.txt"))
        try fileManager.createSymbolicLink(
            at: checkout.appendingPathComponent("escape.txt"),
            withDestinationURL: sibling.appendingPathComponent("secret.txt")
        )
    } catch {
        expect(false, "cannot build the local-file link fixture: \(error)")
    }

    let canonicalApp = checkout.appendingPathComponent("Sources/App.swift")
        .standardizedFileURL.resolvingSymlinksInPath().path

    func resolve(_ destination: String) -> Result<AgentLocalFileLink, AgentLocalFileLinkResolver.Failure> {
        AgentLocalFileLinkResolver.resolve(destination: destination, checkoutRoot: checkout)
    }

    // Resolves: relative, ./, absolute, file:// (with and without localhost),
    // percent-encoded spaces, and every navigation form.
    let resolving: [(String, Int?, Int?)] = [
        ("Sources/App.swift", nil, nil),
        ("./Sources/App.swift", nil, nil),
        (canonicalApp, nil, nil),
        ("file://\(canonicalApp)", nil, nil),
        ("file://localhost\(canonicalApp)", nil, nil),
        ("Sources/App.swift:42", 42, nil),
        ("Sources/App.swift:42:8", 42, 8),
        ("Sources/App.swift#L42", 42, nil),
        ("Sources/App.swift#L42C8", 42, 8)
    ]
    for (destination, line, column) in resolving {
        switch resolve(destination) {
        case let .success(link):
            expect(link.path == canonicalApp,
                   "\(destination) must resolve to the canonical path \(canonicalApp); got \(link.path)")
            expect(link.line == line && link.column == column,
                   "\(destination) must carry line \(String(describing: line)) column \(String(describing: column)); got \(link)")
        case let .failure(reason):
            expect(false, "\(destination) must resolve inside the checkout; refused as \(reason)")
        }
    }

    let encoded = "file://" + checkout.appendingPathComponent("Sources/Two Words.swift").path
        .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
    switch resolve(encoded) {
    case let .success(link):
        expect(link.path.hasSuffix("Two Words.swift"),
               "a percent-encoded local file URL must decode to its real path; got \(link.path)")
    case let .failure(reason):
        expect(false, "a percent-encoded local file URL must resolve; refused as \(reason)")
    }

    // Refused, with the reason that explains which rule stopped it.
    let refusals: [(String, AgentLocalFileLinkResolver.Failure)] = [
        ("Sources/Missing.swift", .notARegularFile),
        // A bare word is prose, not a path: policy stops it before the resolver.
        // Spelled as a path, the same directory reaches the resolver and is
        // refused there for being a directory.
        ("Sources", .notALocalFile),
        ("./Sources", .notARegularFile),
        ("escape.txt", .outsideCheckout),
        ("../checkout-evil/secret.txt", .outsideCheckout),
        ("\(sibling.path)/secret.txt", .outsideCheckout),
        ("https://example.com/App.swift", .notALocalFile),
        ("javascript:alert(1)", .notALocalFile),
        ("file://other-host\(canonicalApp)", .notALocalFile),
        ("file://user:pw@localhost\(canonicalApp)", .notALocalFile),
        ("file://\(canonicalApp)?q=1", .notALocalFile),
        ("~/secret.txt", .notALocalFile),
        ("", .notALocalFile)
    ]
    for (destination, expected) in refusals {
        switch resolve(destination) {
        case let .success(link):
            expect(false, "\(destination.debugDescription) must NOT resolve; it produced \(link.path)")
        case let .failure(reason):
            expect(reason == expected,
                   "\(destination.debugDescription) must be refused as \(expected); got \(reason)")
        }
    }

    // The checkout may be a worktree reached through a symlinked parent (/var →
    // /private/var is exactly this on macOS): containment must still hold.
    let symlinkedRoot = tempRoot.appendingPathComponent("link-to-checkout")
    try? fileManager.createSymbolicLink(at: symlinkedRoot, withDestinationURL: checkout)
    switch AgentLocalFileLinkResolver.resolve(destination: "Sources/App.swift", checkoutRoot: symlinkedRoot) {
    case let .success(link):
        expect(link.path == canonicalApp,
               "a symlinked checkout root must still resolve its own files; got \(link.path)")
    case let .failure(reason):
        expect(false, "a symlinked checkout root must resolve its own files; refused as \(reason)")
    }

    // File-kind classification for the tile's presentation choice.
    let presentations: [(String, FilePreview.Presentation)] = [
        ("/tmp/README.md", .markdown),
        ("/tmp/NOTES.MARKDOWN", .markdown),
        ("/tmp/a.MD", .markdown),
        ("/tmp/notes.md.txt", .sourceText),
        ("/tmp/mdfile", .sourceText),
        ("/tmp/App.swift", .sourceText),
        ("/tmp/no-extension", .sourceText)
    ]
    for (path, expected) in presentations {
        expect(FilePreview.presentation(forPath: path) == expected,
               "\(path) must present as \(expected); got \(FilePreview.presentation(forPath: path))")
    }

    print("Agent local-file link checks passed: \(resolving.count) resolving forms, \(refusals.count) refusals, symlinked-root containment, and \(presentations.count) file-kind classifications")
}
