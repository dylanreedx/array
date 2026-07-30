import ContinuumRevivedAgentContent
import Foundation

func runLinkPolicyChecks() {
    let cases: [(String, AgentLinkDisposition)] = [
        ("https://example.com/docs?q=agent#links", .openExternally),
        ("HTTP://example.com", .openExternally),
        ("mailto:person@example.com", .openExternally),
        ("continuum://pair", .openInternally),
        ("continuum:settings", .openInternally),
        ("file:///Users/example/secret.txt", .displayOnly),
        ("/Users/example/secret.txt", .displayOnly),
        ("../private/notes.txt", .displayOnly),
        ("~/Desktop/token.txt", .displayOnly),
        ("C:\\Users\\example\\secret.txt", .displayOnly),
        ("custom://extension/item", .displayOnly),
        ("relative/path", .displayOnly),
        ("javascript:alert(1)", .displayOnly),
        ("JaVaScRiPt:alert(1)", .displayOnly),
        ("data:text/html,<script>alert(1)</script>", .displayOnly),
        ("https://", .reject),
        ("mailto:", .reject),
        ("not a destination", .reject),
        ("https://example.com/%", .reject),
        ("", .reject)
    ]
    for (destination, expectedDisposition) in cases {
        let actual = AgentLinkPolicy.disposition(for: destination)
        expect(actual == expectedDisposition,
               "link policy classified \(destination.debugDescription) as \(actual), expected \(expectedDisposition)")
    }

    let parser = MarkdownAgentMarkupParser()
    let entryID = AgentNodeID(rawValue: "entry:link-policy")!
    let source = "Read [the guide](https://example.com/guide \"Guide title\"), email <person@example.com>, " +
        "or copy [the local report](file:///Users/example/report.txt)."
    let parsed = parser.parse(source, entryID: entryID, previous: [])
    expect(parsed.diagnostics.isEmpty, "supported links must parse without diagnostics: \(parsed.diagnostics)")
    guard parsed.blocks.count == 1,
          case let .paragraph(inlines) = parsed.blocks[0].payload
    else { fail("link corpus did not produce one semantic paragraph") }

    let links = inlines.compactMap { inline -> (String, String?, [AgentInline])? in
        guard case let .link(destination, title, children) = inline else { return nil }
        return (destination, title, children)
    }
    expect(links.count == 3, "inline link and autolink syntax must produce three semantic links")
    expect(links[0].0 == "https://example.com/guide" && links[0].1 == "Guide title" &&
           links[0].2 == [.text("the guide")],
           "inline links must preserve destination, optional title, and visible label separately")
    expect(links[1].0 == "mailto:person@example.com" && links[1].1 == nil &&
           links[1].2 == [.text("person@example.com")],
           "email autolinks must preserve a readable label and semantic mailto destination")
    expect(links[2].0 == "file:///Users/example/report.txt" &&
           links[2].2 == [.text("the local report")] &&
           AgentLinkPolicy.disposition(for: links[2].0) == .displayOnly,
           "file links must retain copyable label/destination while remaining non-activatable")

    let roundTrip = try? JSONDecoder().decode(
        AgentBlock.self,
        from: JSONEncoder().encode(parsed.blocks[0])
    )
    expect(roundTrip == parsed.blocks[0],
           "semantic link labels, titles, and destinations must survive JSON round-trip")

    verifyFileLinkNegativeWitness()
    print("Link policy checks passed: syntax, autolinks, round-trip, and safe external/internal/display/reject classification")
}

/// Mutates the final pure policy in an isolated package. This required negative
/// witness proves that making file URLs activatable turns the focused assertion
/// red without modifying the working tree.
private func verifyFileLinkNegativeWitness() {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-link-policy-witness-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    do {
        let library = root.appendingPathComponent("Sources/LinkPolicy", isDirectory: true)
        let executable = root.appendingPathComponent("Sources/Witness", isDirectory: true)
        try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: executable, withIntermediateDirectories: true)

        let productionURL = repoRoot.appendingPathComponent("Sources/ContinuumRevivedAgentContent/AgentLink.swift")
        var source = try String(contentsOf: productionURL, encoding: .utf8)
        let safe = "case \"file\":\n            return .displayOnly"
        let unsafe = "case \"file\":\n            return .openExternally"
        expect(source.components(separatedBy: safe).count == 2,
               "link negative witness must find exactly one file-policy branch")
        source = source.replacingOccurrences(of: safe, with: unsafe)
        try source.write(to: library.appendingPathComponent("AgentLink.swift"), atomically: true, encoding: .utf8)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "LinkPolicyWitness", targets: [
            .target(name: "LinkPolicy"),
            .executableTarget(name: "Witness", dependencies: ["LinkPolicy"])
        ])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try """
        import Foundation
        import LinkPolicy
        if AgentLinkPolicy.disposition(for: "file:///Users/example/private.txt") != .displayOnly {
            fputs("FAIL: file URLs must remain visible but non-activatable\\n", stderr)
            Foundation.exit(1)
        }
        """.write(to: executable.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    } catch {
        fail("cannot prepare isolated file-link mutation: \(error)")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "run", "--package-path", root.path,
        "--scratch-path", root.appendingPathComponent(".build").path, "Witness"
    ]
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    do { try process.run() } catch { fail("cannot launch isolated file-link mutation: \(error)") }
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let errorText = String(decoding: errorData, as: UTF8.self)
    expect(process.terminationStatus == 1,
           "activating file URLs must make the isolated check exit 1, got \(process.terminationStatus): \(errorText)")
    expect(errorText.contains("FAIL: file URLs must remain visible but non-activatable"),
           "file-link mutation must fail the safety assertion, stderr was: \(errorText)")

    print("Link policy negative witness passed: mutated file activation exited 1 at the safety assertion")
}
