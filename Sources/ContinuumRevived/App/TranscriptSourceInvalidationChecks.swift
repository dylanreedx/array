import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Exercises live canvas source changes without changing the semantic document.
@MainActor
enum TranscriptSourceInvalidationChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    @MainActor private final class Sources {
        var status: InboxState = .ready
        var statusCallbacks: [UUID: (UUID, (InboxState?) -> Void)] = [:]
        var senders: [UUID: AgentMessageSenderSource.Sender] = [:]
        var senderCallbacks: [UUID: (UUID, () -> Void)] = [:]
        var imageState: AgentImageResourceState = .missing
        var imageRevision: UInt64 = 0
        var imageCallbacks: [UUID: (AgentImageAttachmentID, @MainActor (UInt64) -> Void)] = [:]

        var context: AgentRenderContext {
            AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark,
                imageResources: AgentImageResourceProvider(
                    snapshot: { [self] id in .init(attachmentID: id, state: imageState, revision: imageRevision) },
                    observe: { [self] id, callback in
                        let token = UUID()
                        imageCallbacks[token] = (id, callback)
                        return AgentImageResourceObservation { [weak self] in self?.imageCallbacks[token] = nil }
                    }, hasReliableInvalidation: true),
                agentStatus: AgentReferenceStatusSource(
                    current: { [self] _ in status },
                    subscribe: { [self] id, callback in
                        let token = UUID(); statusCallbacks[token] = (id, callback); return token
                    },
                    unsubscribe: { [self] token in statusCallbacks[token] = nil }, hasReliableNotifications: true),
                agentMessageSenders: AgentMessageSenderSource(
                    current: { [self] id in senders[id] },
                    subscribe: { [self] id, callback in
                        let token = UUID(); senderCallbacks[token] = (id, callback); return token
                    },
                    unsubscribe: { [self] token in senderCallbacks[token] = nil }, hasReliableNotifications: true))
        }
        func publishStatus(_ state: InboxState) {
            status = state
            for (_, callback) in Array(statusCallbacks.values) { callback(state) }
        }
        func publishSender(_ id: UUID) {
            for (target, callback) in Array(senderCallbacks.values) where target == id { callback() }
        }
        func publishImage(_ state: AgentImageResourceState) {
            imageState = state; imageRevision += 1
            for (_, callback) in Array(imageCallbacks.values) { callback(imageRevision) }
        }
    }

    private static func id(_ text: String) -> AgentNodeID { AgentNodeID(rawValue: text)! }
    private static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    private static func occurrences(_ text: String, in source: String) -> Int {
        source.components(separatedBy: text).count - 1
    }

    @MainActor private final class PendingImageProvider {
        var completions: [@MainActor (AgentImageThumbnailResult) -> Void] = []
        var requests: [AgentImageThumbnailRequest] = []
        let identity: AgentImageResourceIdentity

        init(owner: UUID, generation: UInt64) {
            identity = AgentImageResourceIdentity(owner: owner, generation: generation)
        }

        var context: AgentRenderContext {
            AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark,
                imageResources: AgentImageResourceProvider(
                    snapshot: { id in .init(attachmentID: id, state: .available, revision: 7) },
                    requestThumbnail: { [self] _, _, _, completion in
                        completions.append(completion)
                        let request = AgentImageThumbnailRequest()
                        requests.append(request)
                        return request
                    }, hasReliableInvalidation: true, identity: identity))
        }
    }

    /// A cancelled provider is allowed to finish late, even with the same
    /// revision as its replacement. It must not steal the new request or image.
    private static func checkLateImageCompletion() throws {
        // Same owner but a new binding generation may serve different data at
        // the SAME revision; old completions must not affect the replacement.
        let owner = UUID()
        let old = PendingImageProvider(owner: owner, generation: 1)
        let current = PendingImageProvider(owner: owner, generation: 2)
        let imageID = AgentImageAttachmentID(rawValue: "source-race-image")!
        let block = AgentBlock(id: id("source-race-block"), revision: 1, kind: .image,
                               payload: .image(.init(attachment: .init(id: imageID))))
        let entry = AgentEntry(id: id("source-race-entry"), revision: 1, role: .user,
                               provenance: .localPrompt(promptID: nil), lifecycle: .finished, blocks: [block])
        let canvas = AgentTranscriptCanvasView()
        canvas.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        try canvas.updateRenderContext(old.context)
        try canvas.enqueue(document: AgentDocument(version: 1, entries: [entry]),
                           patch: AgentDocumentPatch(fromVersion: 0, toVersion: 1))
        canvas.flushPendingVisualUpdate()
        try expect(old.requests.count == 1 && old.completions.count == 1, "old provider must start an image request")
        try canvas.updateRenderContext(current.context)
        try expect(old.requests[0].isCancelled, "rebind must cancel the old image request")
        try expect(current.requests.count == 1 && current.completions.count == 1, "rebind must request the new provider image")
        let oldImage = NSImage(size: NSSize(width: 12, height: 12))
        let newImage = NSImage(size: NSSize(width: 20, height: 20))
        old.completions[0](.success(.init(attachmentID: imageID, revision: 7, image: oldImage, pixelSize: oldImage.size)))
        try expect(canvas.imageSources[imageID] == nil && canvas.imageRequests[imageID] === current.requests[0],
                   "late cancelled image must not overwrite or discard the current request")
        current.completions[0](.success(.init(attachmentID: imageID, revision: 7, image: newImage, pixelSize: newImage.size)))
        try expect(canvas.imageSources[imageID]?.image === newImage && canvas.imageRequests[imageID] == nil,
                   "current image completion must be displayed")
        old.completions[0](.success(.init(attachmentID: imageID, revision: 7, image: oldImage, pixelSize: oldImage.size)))
        try expect(canvas.imageSources[imageID]?.image === newImage,
                   "a second late completion must not replace the current image")
    }

    @MainActor private final class ZeroWidthImageSource {
        let identity = AgentImageResourceIdentity(owner: UUID(), generation: 1)
        let image = NSImage(size: NSSize(width: 16, height: 16))
        var available = false
        var revision: UInt64 = 0
        var callbacks: [UUID: @MainActor (UInt64) -> Void] = [:]

        var context: AgentRenderContext {
            AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark,
                imageResources: AgentImageResourceProvider(
                    snapshot: { [self] id in
                        .init(attachmentID: id, state: available ? .available : .missing, revision: revision)
                    },
                    requestThumbnail: { [self] id, _, version, completion in
                        completion(.success(.init(attachmentID: id, revision: version,
                                                  image: image, pixelSize: image.size)))
                        return AgentImageThumbnailRequest()
                    },
                    observe: { [self] _, callback in
                        let token = UUID()
                        callbacks[token] = callback
                        return AgentImageResourceObservation { [weak self] in self?.callbacks[token] = nil }
                    }, hasReliableInvalidation: true, identity: identity))
        }

        func hydrate() {
            available = true
            revision += 1
            for callback in Array(callbacks.values) { callback(revision) }
        }
    }

    /// An image can hydrate while layout is temporarily zero-width. Its
    /// dependency and presentation must recover when the SAME width returns.
    private static func checkZeroWidthImageInvalidation() throws {
        let source = ZeroWidthImageSource()
        let attachment = AgentImageAttachmentID(rawValue: "zero-width-image")!
        let blockID = id("zero-width-block")
        let image = AgentBlock(id: blockID, revision: 1, kind: .image,
                               payload: .image(.init(attachment: .init(id: attachment))))
        let entry = AgentEntry(id: id("zero-width-entry"), revision: 1, role: .user,
                               provenance: .localPrompt(promptID: nil), lifecycle: .finished, blocks: [image])
        let canvas = AgentTranscriptCanvasView()
        canvas.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        try canvas.updateRenderContext(source.context)
        try canvas.enqueue(document: AgentDocument(version: 1, entries: [entry]),
                           patch: AgentDocumentPatch(fromVersion: 0, toVersion: 1))
        canvas.flushPendingVisualUpdate()
        try expect(canvas.qaLaidOutText.contains("Missing") && source.callbacks.count == 1,
                   "zero-width fixture must initially render and observe the missing image")
        canvas.setFrameSize(NSSize(width: 0, height: 520))
        source.hydrate()
        canvas.setFrameSize(NSSize(width: 420, height: 520))
        canvas.layoutSubtreeIfNeeded()
        let updated = canvas.qaLaidOutText.contains("Available locally")
        let observing = source.callbacks.count == 1
        let decoded = canvas.imageSources[attachment]?.image === source.image
        print("zero-width image: refreshed on same-width restore: \(updated), observed: \(observing), displayed: \(decoded)")
        try expect(updated && observing && decoded,
                   "hydration at zero width must render, observe, and display when width returns")
    }

    @MainActor private final class GalleryImageSource {
        let identity = AgentImageResourceIdentity(owner: UUID(), generation: 1)
        var ready: Set<AgentImageAttachmentID> = []
        var revisions: [AgentImageAttachmentID: UInt64] = [:]
        var callbacks: [AgentImageAttachmentID: [UUID: @MainActor (UInt64) -> Void]] = [:]
        var requests: [AgentImageAttachmentID: [AgentImageThumbnailRequest]] = [:]
        var completions: [AgentImageAttachmentID: [@MainActor (AgentImageThumbnailResult) -> Void]] = [:]

        var context: AgentRenderContext {
            AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark,
                imageResources: AgentImageResourceProvider(
                    snapshot: { [self] id in
                        .init(attachmentID: id, state: ready.contains(id) ? .available : .missing,
                              revision: revisions[id, default: 0])
                    },
                    requestThumbnail: { [self] id, _, _, completion in
                        let request = AgentImageThumbnailRequest()
                        requests[id, default: []].append(request)
                        completions[id, default: []].append(completion)
                        return request
                    },
                    observe: { [self] id, callback in
                        let token = UUID()
                        callbacks[id, default: [:]][token] = callback
                        return AgentImageResourceObservation { [weak self] in self?.callbacks[id]?[token] = nil }
                    }, hasReliableInvalidation: true, identity: identity))
        }
        func hydrate(_ id: AgentImageAttachmentID) {
            ready.insert(id)
            revisions[id, default: 0] += 1
            for callback in Array(callbacks[id]?.values ?? Dictionary<UUID, @MainActor (UInt64) -> Void>().values) {
                callback(revisions[id, default: 0])
            }
        }
    }

    /// The two cells share a block but have separate request lifetimes.
    /// Hydrating B must keep A's in-flight request; removing A must cancel it.
    private static func checkGalleryInFlightAndRemoval() throws {
        let source = GalleryImageSource()
        let a = AgentImageAttachmentID(rawValue: "gallery-inflight-a")!
        let b = AgentImageAttachmentID(rawValue: "gallery-inflight-b")!
        source.ready.insert(a)
        source.revisions[a] = 1
        let blockID = id("gallery-inflight-block")
        let entryID = id("gallery-inflight-entry")
        let aPayload = AgentImagePayload(attachment: .init(id: a))
        let bPayload = AgentImagePayload(attachment: .init(id: b))
        let block = AgentBlock(id: blockID, revision: 1, kind: .imageGallery,
                               payload: .imageGallery(.init(images: [aPayload, bPayload])))
        var entry = AgentEntry(id: entryID, revision: 1, role: .user,
                               provenance: .localPrompt(promptID: nil), lifecycle: .finished, blocks: [block])
        let canvas = AgentTranscriptCanvasView()
        canvas.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        try canvas.updateRenderContext(source.context)
        try canvas.enqueue(document: AgentDocument(version: 1, entries: [entry]),
                           patch: AgentDocumentPatch(fromVersion: 0, toVersion: 1))
        canvas.flushPendingVisualUpdate()
        guard let first = source.requests[a]?.first, source.completions[a]?.count == 1 else {
            throw Failure(description: "gallery fixture must start A's held thumbnail request")
        }
        source.hydrate(b)
        let retained = canvas.imageRequests[a] === first && !first.isCancelled && source.requests[a]?.count == 1
        let requestedB = source.requests[b]?.count == 1
        print("gallery in-flight: A request retained after B hydrates: \(retained), B requested: \(requestedB)")
        try expect(retained && requestedB, "gallery hydration must not cancel or re-request sibling A")

        entry.revision += 1
        entry.blocks[0].revision += 1
        entry.blocks[0].payload = .imageGallery(.init(images: [bPayload]))
        try canvas.enqueue(document: AgentDocument(version: 2, entries: [entry]),
                           patch: AgentDocumentPatch(fromVersion: 1, toVersion: 2, updated: [entryID, blockID]))
        canvas.flushPendingVisualUpdate()
        let cancelled = first.isCancelled && canvas.imageRequests[a] == nil && source.callbacks[a]?.isEmpty == true
        let keptB = canvas.imageRequests[b] === source.requests[b]?.first
        print("gallery removal: orphan A cancelled: \(cancelled), sibling B retained: \(keptB)")
        try expect(cancelled && keptB, "removing gallery A must cancel only A's orphaned request and observation")
        let oldImage = NSImage(size: NSSize(width: 12, height: 12))
        source.completions[a]?[0](.success(.init(attachmentID: a, revision: 1, image: oldImage, pixelSize: oldImage.size)))
        try expect(canvas.imageSources[a] == nil, "late completion for removed gallery image must stay discarded")
        let newImage = NSImage(size: NSSize(width: 20, height: 20))
        source.completions[b]?[0](.success(.init(attachmentID: b, revision: 1, image: newImage, pixelSize: newImage.size)))
        try expect(canvas.imageSources[b]?.image === newImage, "retained sibling thumbnail must be displayed")
    }

    static func run() throws {
        let source = Sources(), replacement = Sources()
        let agent = UUID(), otherSender = UUID()
        let imageID = AgentImageAttachmentID(rawValue: "shared-source-image")!
        let metadata = AgentImageAttachmentMetadata(id: imageID, displayName: "shared.png")
        let reference = AgentReferencePayload(agentID: agent, parentAgentID: UUID(), displayNameAtSpawn: "Helper",
                                              spawnedAt: Date(timeIntervalSince1970: 0), provider: "codex")
        func block(_ index: Int) -> AgentBlock {
            let identifier = id("source-block-\(index)")
            switch index {
            case 0, 3:
                return AgentBlock(id: identifier, revision: 1, kind: .agentReference, payload: .agentReference(reference))
            case 1, 4:
                return AgentBlock(id: identifier, revision: 1, kind: .agentMessage,
                    payload: .agentMessage(.init(origin: .array, senderAgentID: agent, senderName: "Lead", text: "Message")))
            default:
                return AgentBlock(id: identifier, revision: 1, kind: .image, payload: .image(.init(attachment: metadata)))
            }
        }
        var entries = (0..<6).map { index in
            AgentEntry(id: id("source-entry-\(index)"), revision: 1, role: .system,
                       provenance: .localNotice(reason: "source-check"), lifecycle: .finished, blocks: [block(index)])
        }
        var document = AgentDocument(version: 1, entries: entries)
        weak var releasedCanvas: AgentTranscriptCanvasView?
        try autoreleasepool {
        var canvas: AgentTranscriptCanvasView? = AgentTranscriptCanvasView()
        canvas!.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        try canvas!.updateRenderContext(source.context)
        try canvas!.enqueue(document: document, patch: AgentDocumentPatch(fromVersion: 0, toVersion: 1))
        canvas!.flushPendingVisualUpdate()
        try expect(source.statusCallbacks.count == 1 && source.senderCallbacks.count == 1 && source.imageCallbacks.count == 1,
                   "shared sources must have one subscription each")
        try expect(occurrences("Missing", in: canvas!.qaLaidOutText) == 2, "both image cards must initially be missing")
        try expect(!canvas!.qaControls.contains { $0.title == "Show Lead" }, "unavailable sender must have no reveal action")

        source.publishStatus(.working)
        source.senders[agent] = .init(identityColorName: "blue", hasTile: true)
        source.publishSender(agent)
        source.publishImage(.available)
        settle()
        let chips = canvas!.qaChipRuns.flatMap(\.chips).filter { $0.agentID == agent }
        try expect(chips.count == 2 && chips.allSatisfy { $0.title.contains("Working") },
                   "both old helper cards must reflect a status change")
        try expect(canvas!.qaControls.filter { $0.title == "Show Lead" }.count == 2,
                   "both old message cards must gain their reveal action")
        try expect(occurrences("Available locally", in: canvas!.qaLaidOutText) == 2,
                   "both old image cards must reflect availability")
        try expect(document.entries == entries, "live source changes must not mutate transcript history")

        // Replace the same semantic IDs in place. Their old shared sender must
        // remain subscribed while one row uses it, then be removed after both move.
        source.senders[otherSender] = .init(identityColorName: "red", hasTile: true)
        for index in [1, 4] {
            entries[index].revision += 1
            entries[index].blocks[0].revision += 1
            entries[index].blocks[0].payload = .agentMessage(.init(origin: .array, senderAgentID: otherSender,
                                                                    senderName: "Lead", text: "Message"))
            document.version += 1
            document.entries = entries
            let patch = try AgentDocumentPatch(fromVersion: document.version - 1, toVersion: document.version,
                                               updated: [entries[index].id, entries[index].blocks[0].id])
            try canvas!.enqueue(document: document, patch: patch)
            canvas!.flushPendingVisualUpdate()
        }
        try expect(!source.senderCallbacks.values.contains { $0.0 == agent }
                   && source.senderCallbacks.values.contains { $0.0 == otherSender },
                   "same-ID sender replacement must retire the old source")

        // Rebinding the render context must detach the old providers and use the
        // new providers for every surviving old row.
        replacement.senders[otherSender] = .init(identityColorName: nil, hasTile: false)
        try canvas!.updateRenderContext(replacement.context)
        try expect(source.statusCallbacks.isEmpty && source.senderCallbacks.isEmpty && source.imageCallbacks.isEmpty,
                   "context replacement must detach old providers")
        try expect(!canvas!.qaControls.contains { $0.title == "Show Lead" }
                   && occurrences("Missing", in: canvas!.qaLaidOutText) == 2,
                   "old rows must use the replacement providers")
        releasedCanvas = canvas
        canvas = nil
        }
        // AppKit may retain autoreleased objects until its pool drains, and an
        // isolated deinitializer may enqueue cleanup on the main actor. Poll
        // both the weak reference and observer state with a bounded deadline.
        let teardownDeadline = Date().addingTimeInterval(3)
        while (releasedCanvas != nil || !replacement.statusCallbacks.isEmpty ||
               !replacement.senderCallbacks.isEmpty || !replacement.imageCallbacks.isEmpty),
              Date() < teardownDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try expect(releasedCanvas == nil, "canvas must deallocate when its owner releases it")
        try expect(replacement.statusCallbacks.isEmpty && replacement.senderCallbacks.isEmpty && replacement.imageCallbacks.isEmpty,
                   "releasing the canvas must detach all subscriptions")
        try checkLateImageCompletion()
        try checkZeroWidthImageInvalidation()
        try checkGalleryInFlightAndRemoval()
    }
}
