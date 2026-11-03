import AppKit
import ImageIO
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// A teammate's view of a shared agent's transcript, drawn by the renderer the
/// owner's tile uses (`AgentTranscriptDocumentFeed.makeSurface`), from the
/// owner's own document as the mirror rebuilt it. Nothing here re-describes a
/// block: tools, subagents, plans, diffs and markup render exactly as they do
/// on the host. Only the render context differs: there is no supervisor here,
/// so provider requests show as history and local files do not open.
@MainActor
final class SharedAgentTranscriptView: NSView {
    typealias Wire = SharedAgentTranscriptWire
    typealias Lane = Collaboration.AgentTranscript

    let surface: any AgentTranscriptSurface
    private let toolDetailStore = AgentToolDetailStore()
    private var feed = AgentTranscriptDocumentFeed()
    private let imagePreview = AgentImageQuickPreviewController()
    private var imageDirectory: URL?
    private var imageMetadata: [AgentImageAttachmentID: AgentImageAttachmentMetadata] = [:]
    private(set) var mirror = Wire.Mirror()
    private(set) var cursor: Lane.Cursor?
    private(set) var renderError: (any Error)?
    private(set) var appliedFrames = 0
    private(set) var installedCheckpoints = 0
    /// transcript-subagents: live status for `.agentReference` chips and
    /// message senders. Unavailable until a resolver is supplied.
    var agentStatus: AgentReferenceStatusSource = .unavailable { didSet { refreshRenderContext() } }
    var agentMessageSenders: AgentMessageSenderSource = .unavailable { didSet { refreshRenderContext() } }
    /// transcript-characters: a chip's or message card's character and pose,
    /// from the roster's facts. Unavailable still draws the id's own character, idle.
    var agentCharacters: AgentCharacterSource = .unavailable { didSet { refreshRenderContext() } }
    var onRevealAgent: ((_ agentID: UUID, _ parentAgentID: UUID) -> Void)?
    var onOpenWebLink: ((URL, AgentLinkOpenTarget) -> Void)?
    /// The host's chrome or one of its character sets arrived (agent-chrome).
    var onChromeChange: (() -> Void)?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        surface = AgentTranscriptDocumentFeed.makeSurface(toolDetailStore: toolDetailStore)
        super.init(frame: frameRect)
        addSubview(surface)
        setAccessibilityElement(false)
        refreshRenderContext()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        if surface.frame != bounds { surface.frame = bounds }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshRenderContext()
    }

    /// The document as rendered (what parity compares with the host tile's).
    var qaMirrorDocument: AgentDocument { mirror.document }
    var qaRenderedDocument: AgentDocument { feed.rendered }

    /// Applies one lane read. Returns false when the mirror needs a resnapshot:
    /// the cursor is dropped and the next read starts over. Never guesses.
    @discardableResult
    func receive(_ read: Lane.Read) -> Bool {
        var next = mirror
        var touched = Wire.Mirror.Touched()
        var position: Lane.Cursor?
        do {
            let frames: [Lane.Frame]
            switch read {
            case let .resnapshot(checkpoint, list, _):
                let body = try Wire.decode(Wire.Checkpoint.self, from: checkpoint.body)
                touched = try next.install(body)
                position = .init(generation: checkpoint.generation, through: checkpoint.through)
                installedCheckpoints += 1
                frames = list
            case let .frames(generation, list, _):
                guard let cursor, cursor.generation == generation else { self.cursor = nil; return false }
                position = cursor
                frames = list
            }
            for frame in frames {
                guard let at = position, frame.generation == at.generation else { throw Wire.Mirror.Failure.schema }
                if frame.sequence <= at.through { continue }
                guard frame.sequence == at.through + 1 else { throw Wire.Mirror.Failure.schema }
                let step = try next.apply(try Wire.decode(Wire.Patch.self, from: frame.body))
                touched.ids.formUnion(step.ids); touched.structural = touched.structural || step.structural
                touched.chrome = touched.chrome || step.chrome
                position = .init(generation: at.generation, through: frame.sequence)
                appliedFrames += 1
            }
        } catch {
            renderError = error
            cursor = nil
            return false
        }
        cursor = position
        guard next != mirror else { return true }
        let documentChanged = next.document != mirror.document
        mirror = next
        // Images and tool details change what is drawn without new entries.
        if documentChanged || touched.structural || !touched.ids.isEmpty { present(touched) }
        if touched.chrome { onChromeChange?() }
        return true
    }

    func qaImageState(for id: AgentImageAttachmentID) -> AgentImageResourceState { imageResources.snapshot(id).state }

    func qaImageThumbnail(for id: AgentImageAttachmentID) async -> AgentImageThumbnail? {
        await withCheckedContinuation { continuation in
            _ = imageResources.requestThumbnail(id: id, targetPixelSize: NSSize(width: 128, height: 128), revision: 1) { result in
                if case let .success(thumbnail) = result { continuation.resume(returning: thumbnail) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    /// Another agent: forget this one's document.
    func reset() {
        guard cursor != nil || !mirror.document.entries.isEmpty || mirror.chrome != nil else { return }
        mirror = Wire.Mirror(); cursor = nil
        present(.init(ids: [], structural: true))
        onChromeChange?()
    }

    /// The host tile's tail, drawn on this surface: the working gyro and its
    /// words, or the settled "Worked for …".
    func applyTail(working: Bool, text: String?, settled: String?) {
        surface.setTurnInFlight(working)
        if let settled {
            surface.setSettledTailStatus(settled)
            return
        }
        surface.setThinkingStatusText(text ?? "")
        surface.setThinkingIndicatorVisible(working)
    }

    private func present(_ touched: Wire.Mirror.Touched) {
        do {
            var metadata: [AgentImageAttachmentID: AgentImageAttachmentMetadata] = [:]
            func collect(_ block: AgentBlock) {
                switch block.payload {
                case let .image(value): metadata[value.attachment.id] = value.attachment
                case let .imageGallery(value): value.images.forEach { metadata[$0.attachment.id] = $0.attachment }
                default: break
                }
                block.children.forEach(collect)
            }
            mirror.document.entries.forEach { $0.blocks.forEach(collect) }
            imageMetadata = metadata
            func presented(_ block: AgentBlock) -> AgentBlock {
                var copy = mirror.toolDetails[block.id]?.applying(to: block) ?? block
                copy.children = block.children.map(presented)
                return copy
            }
            let entries = mirror.document.entries.map { entry in
                var copy = entry
                copy.blocks = entry.blocks.map(presented)
                return copy
            }
            try feed.present(entries, touched: touched.ids, structural: touched.structural, final: true, to: surface)
            renderError = nil
            refreshRenderContext()
        } catch {
            renderError = error
        }
    }

    private func refreshRenderContext() {
        try? surface.updateRenderContext(AgentRenderContext(
            actions: AgentRenderActions { [weak self] action in self?.perform(action) },
            tokens: .transcript,
            appearance: effectiveTokenTheme,
            imageResources: imageResources,
            agentStatus: agentStatus,
            agentMessageSenders: agentMessageSenders,
            agentCharacters: agentCharacters,
            // No runner answers a provider request from here: approvals and
            // questions read as history, with no buttons that cannot work.
            canRespondToRequests: false))
    }

    private var imageResources: AgentImageResourceProvider {
        AgentImageResourceProvider(snapshot: { [weak self] id in
            MainActor.assumeIsolated {
                let available = self?.mirror.images.data(for: id) != nil
                let metadata = self?.imageMetadata[id]
                let tooLarge = (metadata?.byteCount ?? 0) > UInt64(SharedAgentTranscriptImages.maxImageBytes)
                    || (metadata?.pixelWidth ?? 0) > 4096 || (metadata?.pixelHeight ?? 0) > 4096
                let state: AgentImageResourceState = available ? .available : (tooLarge ? .tooLargeToShare : .missing)
                return AgentImageResourceSnapshot(attachmentID: id, state: state,
                    revision: available ? 1 : 0,
                    pixelSize: metadata.flatMap { value in value.pixelWidth.flatMap { width in value.pixelHeight.map { NSSize(width: CGFloat(width), height: CGFloat($0)) } } },
                    displayName: metadata?.displayName, contentType: metadata?.contentType, byteCount: metadata?.byteCount,
                    canPreview: available, canCopy: available, canSave: available, canReveal: false)
            }
        }, requestThumbnail: { [weak self] id, target, revision, completion in
            MainActor.assumeIsolated {
                let request = AgentImageThumbnailRequest()
                let data = self?.mirror.images.data(for: id)
                Task { @MainActor in
                    guard !request.isCancelled else { return }
                    guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                        completion(.failed); return
                    }
                    let maxDimension = max(1, min(1024, Int(ceil(max(target.width, target.height)))))
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxDimension]
                    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                        if !request.isCancelled { completion(.failed) }; return
                    }
                    guard !request.isCancelled else { return }
                    let size = NSSize(width: cgImage.width, height: cgImage.height)
                    completion(.success(AgentImageThumbnail(attachmentID: id, revision: revision,
                        image: NSImage(cgImage: cgImage, size: size), pixelSize: size)))
                }
                return request
            }
        })
    }

    private func imageResource(_ id: AgentImageAttachmentID) -> AgentImageActionResource? {
        guard let data = mirror.images.data(for: id) else { return nil }
        let directory = imageDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("array-shared-images-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            imageDirectory = directory
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source) as String? else { return nil }
            let suffix: String
            switch type {
            case "public.png": suffix = "png"
            case "public.jpeg": suffix = "jpg"
            case "com.compuserve.gif": suffix = "gif"
            case "public.tiff": suffix = "tiff"
            case "public.heic": suffix = "heic"
            default: suffix = "image"
            }
            let file = directory.appendingPathComponent(SharedAgentTranscriptImages.digest(data) + "." + suffix)
            if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
            return AgentImageActionResource(attachmentID: id, localFileURL: file)
        } catch { return nil }
    }

    deinit {
        if let imageDirectory { try? FileManager.default.removeItem(at: imageDirectory) }
    }

    /// Read-only. Local paths belong to the owner's Mac and do not open here.
    private func perform(_ action: AgentRenderAction) {
        switch action {
        case let .activateLink(_, url, target): onOpenWebLink?(url, target)
        case let .revealAgent(_, agentID, parentAgentID): onRevealAgent?(agentID, parentAgentID)
        case let .previewImage(_, attachmentID):
            if let resource = imageResource(attachmentID) { imagePreview.preview(localFileURL: resource.localFileURL) }
        case let .copyImage(_, attachmentID):
            if let resource = imageResource(attachmentID) { AgentImageAppKitActions.copy(resource) }
        case let .saveImageAs(_, attachmentID):
            if let resource = imageResource(attachmentID) { AgentImageAppKitActions.saveAs(resource, from: self) }
        default: break
        }
    }
}

extension SharedAgentTranscriptView {
    /// The guest's transcript as the appearance census renders it: a prompt,
    /// a reply with markup and a tool call, rebuilt from a checkpoint the way
    /// a lane read delivers one.
    static func appearanceFixture(size: NSSize) -> SharedAgentTranscriptView {
        let thread = "appearance"
        var model = ManagedAgentTranscriptModel(threadId: thread)
        model.appendUserPrompt("Map every state the checkout can be in.")
        model.ingest(.turnStarted(threadId: thread, turnId: "t1"))
        model.ingest(.itemStarted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, title: "rg -n \"enum CheckoutState\" Sources"))
        model.ingest(.itemCompleted(threadId: thread, itemId: "cmd-1", kind: .commandExecution, status: .completed))
        model.ingest(.contentDelta(threadId: thread, turnId: "t1", streamKind: .assistant,
                                   delta: "**Seven states.** `Cart`, `Address`, `Payment`, plus:\n\n- Declined\n- Abandoned\n"))
        model.ingest(.turnCompleted(threadId: thread, turnId: "t1", outcome: .completed, errorMessage: nil))
        _ = model.flushPendingStreamingMarkup()
        let view = SharedAgentTranscriptView(frame: NSRect(origin: .zero, size: size))
        let checkpoint = Wire.Checkpoint(entries: model.document.entries, omittedEntries: 0)
        if let body = try? Wire.encode(checkpoint) {
            view.receive(.resnapshot(.init(generation: 1, through: 1, body: body), frames: [], more: false))
        }
        return view
    }
}
