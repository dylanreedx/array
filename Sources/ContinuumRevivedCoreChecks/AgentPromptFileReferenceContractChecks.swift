import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation
import UniformTypeIdentifiers

private func fileReference(_ index: Int, path: String? = nil) -> AgentPromptFileReference {
    AgentPromptFileReference(
        displayName: "notes-\(index).md",
        contentType: "net.daringfireball.markdown",
        fileURL: URL(fileURLWithPath: path ?? "/tmp/continuum notes \(index).md")
    )
}

/// Witnesses the reference-not-embed contract for dropped/pasted non-image
/// files: every provider adapter materializes a file reference as its own
/// literal `@/path` argv token (agent Reads it), no shell is introduced for a
/// hostile path, an attachment-only prompt is sendable, and no local path ever
/// enters the syncable transcript document.
func runAgentPromptFileReferenceContractChecks() {
    let model = "provider/model"
    let thinking = "medium"

    // Attachment-only (no prose) is a sendable prompt — parity with images.
    let refOnly = AgentPrompt(fileReferences: [fileReference(1, path: "/tmp/one readme.md")])
    expect(!refOnly.isEmpty && AgentPrompt(text: "   ").isEmpty,
           "AgentPrompt emptiness must treat a file reference as sendable while rejecting whitespace-only text")

    // Pi: each reference is its own argv segment (spaces survive intact).
    // extensionPaths: [] isolates this from C8's default `-e` injection
    // (covered separately by StrictAgentHarnessChecks and
    // PiExtensionInstallerChecks).
    let piArgs = PiAgentRunner.processArguments(
        model: model, thinking: thinking, sessionId: nil, extraArgs: [], prompt: refOnly, extensionPaths: []
    )
    expect(Array(piArgs.suffix(2)) == ["--no-session", "@/tmp/one readme.md"],
           "Pi adapter must materialize a file reference as an @path argv token, got \(piArgs)")

    // Unbounded references, mixed with text, all materialize as @path segments.
    let count = 12
    let many = AgentPrompt(text: "summarize", fileReferences: (0..<count).map { fileReference($0) })
    let manySegments = PiAgentRunner.promptArgumentSegments(many)
    expect(manySegments.count == count + 1,
           "multiple file references must not hit an arbitrary cap; got \(manySegments.count - 1) reference segment(s)")
    expect(manySegments.dropFirst().allSatisfy { $0.hasPrefix("@/tmp/continuum notes ") },
           "every file reference must materialize as an @path segment, got \(manySegments)")

    // Claude/Codex join text + references with newlines into one positional arg;
    // a path with spaces stays whole because it is its own line, not shell-split.
    let mixed = AgentPrompt(
        text: "review",
        imageAttachments: [],
        fileReferences: [fileReference(3, path: "/tmp/design doc.md"), fileReference(4)]
    )
    let claudeArg = ClaudeAgentRunner.promptArgument(mixed)
    expect(claudeArg == "review\n@/tmp/design doc.md\n@/tmp/continuum notes 4.md",
           "Claude adapter must newline-join text and each @path reference, got \(claudeArg)")
    let codexArg = CodexCLIBackend.promptArgument(mixed)
    expect(codexArg == claudeArg,
           "Codex adapter must join text and file references identically to Claude, got \(codexArg)")

    // Images then file references, deterministic order, in one prompt.
    let both = AgentPrompt(
        text: "compare",
        imageAttachments: [AgentPromptImageAttachment(
            metadata: AgentImageAttachmentMetadata(
                id: AgentImageAttachmentID(rawValue: "img-1")!,
                displayName: "shot.png", contentType: "image/png",
                byteCount: 1, pixelWidth: 2, pixelHeight: 3
            ),
            fileURL: URL(fileURLWithPath: "/tmp/shot.png")
        )],
        fileReferences: [fileReference(5, path: "/tmp/spec.md")]
    )
    let bothSegments = PiAgentRunner.promptArgumentSegments(both)
    expect(bothSegments == ["compare", "@/tmp/shot.png", "@/tmp/spec.md"],
           "images precede file references in a deterministic argv order, got \(bothSegments)")

    // A hostile path must pass through as a literal argv element — no shell.
    let hostilePath = "/tmp/space and $(touch SHOULD_NOT_RUN); `rm -rf nope`.md"
    let hostile = AgentPrompt(text: "look", fileReferences: [fileReference(7, path: hostilePath)])
    let hostileArgs = PiAgentRunner.processArguments(
        model: model, thinking: thinking, sessionId: nil, extraArgs: [], prompt: hostile, extensionPaths: []
    )
    expect(Array(hostileArgs.suffix(2)) == ["look", "@\(hostilePath)"],
           "Pi adapter must preserve a metacharacter reference path as a literal argv element, got \(hostileArgs)")
    expect(!hostileArgs.contains("bash") && !hostileArgs.contains("-lc"),
           "Pi adapter must not introduce a shell when passing file reference paths, got \(hostileArgs)")

    // The transcript must retain path-free file metadata so the sent message can
    // show the same attachment chips as the composer, while the local path remains
    // a transport-only capability that never enters syncable/persisted content.
    let promptID = AgentNodeID(rawValue: "submission:file-ref-contract")!
    var projection = AgentTranscriptProjection(threadId: "file-ref-contract-thread")
    try! projection.appendUserPrompt(id: promptID, prompt: hostile)
    let encoded = try! JSONEncoder().encode(projection.document)
    let json = String(decoding: encoded, as: UTF8.self)
    expect(!json.contains(hostilePath) && !json.contains("@\(hostilePath)"),
           "syncable/persisted transcript document must never carry a local file reference path, got \(json)")
    expect(json.contains("notes-7.md") && json.contains("file-references"),
           "transcript document must retain path-free file-reference metadata for the sent-message attachment rail, got \(json)")
    let entryKinds = projection.document.entries.first?.blocks.map(\.kind.rawValue) ?? []
    expect(entryKinds == ["file-references", "paragraph"],
           "sent file attachments must project above the user message prose, got \(entryKinds)")
    let body = projection.compatibilityRows.map(\.body).joined(separator: "\n")
    expect(body == "look",
           "visible transcript prose must be the prompt text alone, not the reference path; body was \(body)")

    // The reference allowlist: text/source/markup + PDF are referenceable;
    // images take the embedding path; binaries and unknown types are rejected.
    let referenceable: [UTType] = [.plainText, .text, .pdf, .xml, .sourceCode, .swiftSource, .json, .html, .yaml, .commaSeparatedText]
    for type in referenceable {
        expect(AgentFileReferenceRules.isReferenceableContentType(type.identifier),
               "\(type.identifier) is a document the Read tool consumes and must be referenceable")
    }
    let rejected: [UTType] = [.png, .jpeg, .tiff, .gif, .heic, .zip, .mpeg4Movie, .mp3, .archive, .executable]
    for type in rejected {
        expect(!AgentFileReferenceRules.isReferenceableContentType(type.identifier),
               "\(type.identifier) is an image/binary and must NOT be referenceable (images embed; binaries are rejected)")
    }
    expect(!AgentFileReferenceRules.isReferenceableContentType("totally.bogus.unregistered.type"),
           "an unrecognized content-type identifier must be rejected, not treated as referenceable")

    print("AgentPrompt file-reference contract checks passed: attachment-only sendability, per-adapter @path argv (pi segments, claude/codex newline-join), space-safe paths, deterministic image→file order, literal hostile-path argv without a shell, and path-free transcript projection")
}
