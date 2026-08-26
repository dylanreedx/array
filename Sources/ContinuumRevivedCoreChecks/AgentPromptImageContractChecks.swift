import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

private func imageMetadata(_ index: Int) -> AgentImageAttachmentMetadata {
    AgentImageAttachmentMetadata(
        id: AgentImageAttachmentID(rawValue: "local-image-\(index)")!,
        displayName: "image-\(index).png",
        contentType: "image/png",
        byteCount: UInt64(index + 1),
        pixelWidth: UInt(index + 10),
        pixelHeight: UInt(index + 20)
    )
}

private func localAttachment(_ index: Int, path: String? = nil) -> AgentPromptImageAttachment {
    AgentPromptImageAttachment(
        metadata: imageMetadata(index),
        fileURL: URL(fileURLWithPath: path ?? "/tmp/continuum image \(index).png")
    )
}

func runAgentPromptImageContractChecks() {
    typealias Runner = PiAgentRunner
    let model = "provider/model"
    let thinking = "medium"

    let legacy = Runner.processArguments(
        model: model,
        thinking: thinking,
        sessionId: "session",
        extraArgs: ["--tools", "read"],
        prompt: "describe the screen"
    )
    let textPrompt = Runner.processArguments(
        model: model,
        thinking: thinking,
        sessionId: "session",
        extraArgs: ["--tools", "read"],
        prompt: AgentPrompt("describe the screen")
    )
    expect(legacy == textPrompt,
           "AgentPrompt text-only wrapper must preserve the old Pi argv exactly; legacy \(legacy), AgentPrompt \(textPrompt)")
    expect(Array(legacy.suffix(2)) == ["read", "describe the screen"],
           "text-only compatibility must keep the prompt as the trailing positional argument, got \(legacy)")

    let imageOnly = AgentPrompt(imageAttachments: [localAttachment(1, path: "/tmp/one image.png")])
    expect(!imageOnly.isEmpty && AgentPrompt(text: "   ").isEmpty,
           "AgentPrompt emptiness must treat attachments as sendable while rejecting whitespace-only text")
    let sendTurn = AgentSendTurnInput(threadId: "thread", prompt: imageOnly)
    expect(sendTurn.text.isEmpty && sendTurn.prompt.imageAttachments.count == 1,
           "image-only AgentPrompt must be accepted by the provider-neutral adapter contract")
    // extensionPaths: [] isolates the prompt/attachment argv shape being
    // tested here from C8's default `-e` injection (covered separately by
    // StrictAgentHarnessChecks and PiExtensionInstallerChecks).
    let imageOnlyArgs = Runner.processArguments(model: model, thinking: thinking, sessionId: nil, extraArgs: [], prompt: imageOnly, extensionPaths: [])
    expect(Array(imageOnlyArgs.suffix(2)) == ["--no-session", "@/tmp/one image.png"],
           "image-only AgentPrompt must be accepted at the Pi adapter boundary as an @path argv token, got \(imageOnlyArgs)")

    let count = 12
    let many = AgentPrompt(text: "compare", imageAttachments: (0..<count).map { localAttachment($0) })
    let manySegments = Runner.promptArgumentSegments(many)
    expect(manySegments.count == count + 1,
           "multiple image attachments must not hit an arbitrary product cap; got \(manySegments.count - 1) image segment(s)")
    expect(manySegments.dropFirst().allSatisfy { $0.hasPrefix("@/tmp/continuum image ") },
           "every image attachment must materialize as an @path segment, got \(manySegments)")

    let hostilePath = "/tmp/space and $(touch SHOULD_NOT_RUN); `rm -rf nope`.png"
    let hostile = AgentPrompt(text: "look", imageAttachments: [localAttachment(7, path: hostilePath)])
    let hostileArgs = Runner.processArguments(model: model, thinking: thinking, sessionId: nil, extraArgs: [], prompt: hostile, extensionPaths: [])
    expect(Array(hostileArgs.suffix(2)) == ["look", "@\(hostilePath)"],
           "Pi adapter must preserve a metacharacter path as literal argv elements without shell interpolation, got \(hostileArgs)")
    expect(!hostileArgs.contains("bash") && !hostileArgs.contains("-lc") && hostileArgs.contains("@\(hostilePath)"),
           "Pi adapter must not introduce a shell when passing image paths, got \(hostileArgs)")

    let promptID = AgentNodeID(rawValue: "submission:image-contract")!
    var projection = AgentTranscriptProjection(threadId: "image-contract-thread")
    try! projection.appendUserPrompt(id: promptID, prompt: hostile)
    let body = projection.compatibilityRows.map(\.body).joined(separator: "\n")
    expect(body == "look" && !body.contains(hostilePath),
           "visible transcript prose must not include local image paths; body was \(body)")
    let encoded = try! JSONEncoder().encode(projection.document)
    let json = String(decoding: encoded, as: UTF8.self)
    expect(!json.contains(hostilePath) && !json.contains("@\(hostilePath)"),
           "syncable/persisted transcript document must carry image metadata but no local file path, got \(json)")
    expect(json.contains("local-image-7") && json.contains("image-gallery"),
           "transcript document must retain path-free image identity/gallery semantics, got \(json)")

    let image = AgentImagePayload(attachment: imageMetadata(42), caption: [.text("caption")])
    let gallery = AgentBlock(
        id: AgentNodeID(rawValue: "block:gallery-round-trip")!,
        kind: .imageGallery,
        payload: .imageGallery(.init(images: [image, AgentImagePayload(attachment: imageMetadata(43))]))
    )
    let roundTripData = try! JSONEncoder().encode(gallery)
    let decoded = try! JSONDecoder().decode(AgentBlock.self, from: roundTripData)
    expect(decoded == gallery,
           "semantic image/gallery block payload must round-trip through Codable")

    print("AgentPrompt image contract checks passed: text-only compatibility, image-only adapter acceptance, unbounded multiple attachments, path-literal argv, path-free transcript projection, and image/gallery Codable round-trip")
}
