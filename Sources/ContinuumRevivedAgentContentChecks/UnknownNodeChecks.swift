import ContinuumRevivedAgentContent
import Foundation

// Ticket: docs/38-tickets/91-agent-tile-ux/P1.7-unknown-node-forward-compat.md

private func unknownID(_ value: String) -> AgentNodeID {
    guard let id = AgentNodeID(rawValue: value) else { fail("unknown-node fixture id \(value) is invalid") }
    return id
}

/// Copies the final AgentContent sources into an isolated package, mutates the
/// production fallback implementation to interpolate the opaque debug label,
/// and proves the ordinary sentinel assertion turns red. The working tree and
/// the check executable itself remain untouched.
private func verifyUnsafeFallbackNegativeWitness() {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-unknown-node-witness-\(UUID().uuidString)", isDirectory: true)
    let copiedSources = temporaryRoot.appendingPathComponent("Sources/ContinuumRevivedAgentContent", isDirectory: true)
    let witnessSources = temporaryRoot.appendingPathComponent("Sources/UnsafeFallbackWitness", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    do {
        try fileManager.createDirectory(
            at: temporaryRoot.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(
            at: repoRoot.appendingPathComponent("Sources/ContinuumRevivedAgentContent", isDirectory: true),
            to: copiedSources
        )
        try fileManager.createDirectory(at: witnessSources, withIntermediateDirectories: true)

        let fallbackURL = copiedSources.appendingPathComponent("AgentUnknownPayload.swift")
        var fallbackSource = try String(contentsOf: fallbackURL, encoding: .utf8)
        let safeImplementation = #"        "Unsupported content: \(kind.rawValue)""#
        let unsafeImplementation = #"        "Unsupported content: \(kind.rawValue) \(payload)""#
        expect(fallbackSource.components(separatedBy: safeImplementation).count == 2,
               "negative witness must find exactly one final production fallback implementation to mutate")
        fallbackSource = fallbackSource.replacingOccurrences(of: safeImplementation, with: unsafeImplementation)
        try fallbackSource.write(to: fallbackURL, atomically: true, encoding: .utf8)

        let package = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "UnknownNodeNegativeWitness",
            platforms: [.macOS(.v13)],
            dependencies: [
                .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")
            ],
            targets: [
                .target(
                    name: "ContinuumRevivedAgentContent",
                    dependencies: [
                        .product(name: "Markdown", package: "swift-markdown")
                    ]
                ),
                .executableTarget(name: "UnsafeFallbackWitness", dependencies: ["ContinuumRevivedAgentContent"])
            ]
        )
        """
        try package.write(
            to: temporaryRoot.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let witness = #"""
        import ContinuumRevivedAgentContent
        import Foundation

        let sentinel = "CONTINUUM_SECRET_DO_NOT_RENDER_91F7"
        let block = AgentBlock(
            id: AgentNodeID(rawValue: "block:unsafe-witness")!,
            kind: AgentBlockKind(rawValue: "provider.future-card.v3")!,
            payload: .opaque(.init(debugLabel: sentinel, value: .object(["secret": .string(sentinel)])))
        )
        let visibleFallback = block.safeFallbackSummary
        let accessibilityLabel = block.safeFallbackAccessibilityLabel
        if visibleFallback.contains(sentinel) || accessibilityLabel.contains(sentinel) {
            fputs("FAIL: opaque payload secrets must never reach fallback or accessibility text\n", stderr)
            Foundation.exit(1)
        }
        """#
        try witness.write(
            to: witnessSources.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
    } catch {
        fail("cannot prepare isolated unsafe-fallback production mutation: \(error)")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "run",
        "--package-path", temporaryRoot.path,
        "--scratch-path", temporaryRoot.appendingPathComponent(".build").path,
        "UnsafeFallbackWitness"
    ]
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors

    do {
        try process.run()
    } catch {
        fail("cannot launch unsafe-fallback production mutation: \(error)")
    }
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let errorText = String(decoding: errorData, as: UTF8.self)
    let expectedFailure = "FAIL: opaque payload secrets must never reach fallback or accessibility text"
    expect(process.terminationStatus == 1,
           "unsafe production fallback mutation must make the isolated check exit 1, got \(process.terminationStatus): \(errorText)")
    expect(errorText.contains(expectedFailure),
           "unsafe production fallback mutation must fail the sentinel assertion, stderr was: \(errorText)")

    print("Unknown node negative witness passed: mutated production fallback source exited 1 at the sentinel assertion")
}

func runUnknownNodeChecks() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    // AgentOpaqueValue uses native JSON shape, including the distinction between
    // integral and fractional numbers, rather than a synthesized enum envelope.
    let canonicalPayload = #"{"array":[null,true,-7,1.25,"text",{"nested":"value"}],"object":{"enabled":false,"version":2}}"#
    do {
        let decoded = try JSONDecoder().decode(AgentOpaqueValue.self, from: Data(canonicalPayload.utf8))
        let reencoded = try encoder.encode(decoded)
        expect(String(decoding: reencoded, as: UTF8.self) == canonicalPayload,
               "opaque JSON must round-trip with byte-equivalent canonical encoding")
    } catch {
        fail("opaque JSON shape round-trip failed: \(error)")
    }

    let sentinel = "CONTINUUM_SECRET_DO_NOT_RENDER_91F7"
    let futureKind = AgentBlockKind(rawValue: "provider.future-card.v3")!
    let child = AgentBlock(
        id: unknownID("block:future-child"),
        kind: AgentBlockKind(rawValue: "provider.future-child")!,
        payload: .opaque(.init(
            debugLabel: "child-\(sentinel)",
            value: .object(["secret": .string(sentinel), "preserved": .integer(9)])
        ))
    )
    let unknown = AgentBlock(
        id: unknownID("block:future-root"),
        revision: 4,
        kind: futureKind,
        payload: .opaque(.init(
            debugLabel: "future-\(sentinel)",
            value: .object([
                "token": .string(sentinel),
                "metadata": .array([.bool(true), .null, .number(2.5)])
            ])
        )),
        children: [child]
    )
    let document = AgentDocument(entries: [AgentEntry(
        id: unknownID("entry:future"),
        role: .assistant,
        provenance: .providerItem(provider: "fixture", itemID: "future-1"),
        blocks: [unknown]
    )])

    do {
        let encoded = try encoder.encode(document)
        let decoded = try JSONDecoder().decode(AgentDocument.self, from: encoded)
        let reencoded = try encoder.encode(decoded)
        expect(decoded == document, "unknown root and child nodes must survive document decoding")
        expect(reencoded == encoded, "unknown document JSON bytes must be stable after canonical round-trip")
        expect(decoded.entries[0].blocks[0].children == [child],
               "opaque children must not be silently discarded")
    } catch {
        fail("unknown document round-trip failed: \(error)")
    }

    let summary = unknown.safeFallbackSummary
    let accessibilityLabel = unknown.safeFallbackAccessibilityLabel
    expect(!summary.contains(sentinel) && !accessibilityLabel.contains(sentinel),
           "opaque payload secrets must never reach fallback or accessibility text")
    expect(summary == "Unsupported content: provider.future-card.v3",
           "fallback summary must be derived only from the validated semantic kind")
    expect(accessibilityLabel == summary,
           "unknown fallback accessibility must use the same safe summary")

    expect(!unknown.allowsInteraction(rendererRegistered: false),
           "an unknown fallback without a renderer must be non-interactive")
    expect(unknown.allowsInteraction(rendererRegistered: true),
           "an explicitly registered renderer may provide unknown-kind interactions")
    let paragraph = AgentBlock(id: unknownID("block:known"), kind: .paragraph, payload: .paragraph([.text("known")]))
    expect(paragraph.allowsInteraction(rendererRegistered: false),
           "unknown fallback policy must not disable typed built-in content")

    verifyUnsafeFallbackNegativeWitness()
    print("Unknown node checks passed: native JSON shape, canonical document round-trip, opaque children, payload-free fallback/accessibility, and renderer-gated interaction")
}
