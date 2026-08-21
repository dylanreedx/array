import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import Foundation

/// Provider-neutral adapter from runtime events to the semantic transcript.
///
/// Runtime facts stop here: AgentContent never imports Core, and this projector
/// never infers requests, capabilities, or work from prose or tool names.
public struct AgentTranscriptProjection: Sendable {
    public private(set) var threadId: String
    public private(set) var reducer: AgentDocumentReducer
    public private(set) var currentStatus: AgentStatus = .configuring
    public private(set) var events: [AgentRuntimeEvent] = []
    public private(set) var rejectedMutationCount = 0
    /// Production-facing deterministic oracle for streamed Markdown parser work.
    /// Source deltas are still appended losslessly; this count advances only when
    /// the accumulated source is reparsed for presentation.
    public private(set) var streamingMarkupParseCount = 0

    private struct OpenStream: Equatable, Sendable {
        var turnID: String
        var kind: ContentStreamKind
        var entryID: AgentNodeID
        var buffer: StreamingMarkupBuffer
        var scheduler: StreamingMarkupParseScheduler
    }

    private static let eventWindow = 400
    private var openStream: OpenStream?
    private var runCountsByTurn: [String: Int] = [:]
    private var itemEntries: [String: AgentNodeID] = [:]
    private var itemBlocks: [String: AgentNodeID] = [:]
    private var statusableItems = Set<String>()
    private var activeItemIDs = Set<String>()
    private var completedStatuses: [String: ItemStatus] = [:]
    private var compatibilityIDs: [AgentNodeID: String] = [:]
    private var rawMarkupSourcesByEntryID: [AgentNodeID: String] = [:]
    private var requestEntries: [String: AgentNodeID] = [:]
    private var requestBlocks: [String: AgentNodeID] = [:]
    private var referencedAgentIDs = Set<UUID>()
    private var localSequence = 0
    private var runtimeErrorSequence = 0
    private let markupParser = MarkdownAgentMarkupParser()
    private let monotonicNow: @Sendable () -> TimeInterval

    public init(threadId: String) {
        self.init(threadId: threadId, monotonicNow: { ProcessInfo.processInfo.systemUptime })
    }

    public init(
        threadId: String,
        monotonicNow: @escaping @Sendable () -> TimeInterval
    ) {
        self.threadId = threadId
        self.reducer = AgentDocumentReducer()
        self.monotonicNow = monotonicNow
    }

    public var document: AgentDocument { reducer.document }
    public var activeToolCount: Int { activeItemIDs.count }
    public var compatibilityMarkupSourcesByEntryID: [AgentNodeID: String] {
        guard let openStream else { return rawMarkupSourcesByEntryID }
        var sources = rawMarkupSourcesByEntryID
        sources[openStream.entryID] = openStream.buffer.source
        return sources
    }
    /// Deterministic oracle: only closed entries are retained here. The one open
    /// stream source is projected on demand by `compatibilityMarkupSourcesByEntryID`.
    public var finalizedCompatibilityMarkupSourceCount: Int { rawMarkupSourcesByEntryID.count }

    /// Monotonic deadline for the delayed parse needed when a provider sends a
    /// delta inside the coalescing window and then pauses. Nil means no streamed
    /// Markdown parse is pending.
    public var nextStreamingMarkupParseDeadline: TimeInterval? {
        guard let openStream else { return nil }
        return openStream.scheduler.nextReadyTime(now: monotonicNow())
    }

    /// Production timer seam: applies the pending parse only when the injected
    /// monotonic clock has reached the scheduler deadline.
    @discardableResult
    public mutating func flushPendingStreamingMarkupIfDue() -> Bool {
        let mutations = scheduledMarkupMutationsForOpenStream()
        guard !mutations.isEmpty else { return false }
        apply(mutations)
        return true
    }

    /// Boundary seam for a live view that is about to detach/reset. It parses the
    /// latest lossless source without finishing the provider-owned open entry.
    @discardableResult
    public mutating func flushPendingStreamingMarkup() -> Bool {
        guard openStream?.scheduler.flush() == true else { return false }
        let mutations = parsedMarkupMutationsForOpenStream()
        apply(mutations)
        return true
    }

    /// Produces the small semantic writes for one event. Calling this method is
    /// stateful because stream boundaries and provider item completion span
    /// events; callers should apply the returned mutations in order.
    public mutating func mutations(for event: AgentRuntimeEvent) -> [AgentDocumentMutation] {
        switch event {
        case .sessionStateChanged(let state) where state == .ready || state == .stopped || state == .error:
            return closeStreamingRun()

        case .turnStarted(let tid, _) where tid == threadId:
            return closeStreamingRun()

        case .contentDelta(let tid, let turnID, let kind, let delta) where tid == threadId:
            switch kind {
            case .assistant, .reasoning:
                return markupMutations(turnID: turnID, kind: kind, delta: delta)
            case .commandOutput:
                var result = closeStreamingRun()
                let entryID = makeID(scope: "turn", providerID: turnID, suffix: "output:\(nextRun(in: turnID))")
                let blockID = childID(of: entryID, key: "command-output")
                compatibilityIDs[entryID] = "output-\(document.entries.count + result.beginEntryCount + 1)"
                result += [
                    .beginEntry(id: entryID, role: .system, provenance: .providerItem(provider: "runtime", itemID: turnID)),
                    .upsertStructured(entryID: entryID, block: AgentBlock(
                        id: blockID,
                        kind: .commandOutput,
                        payload: .commandOutput(.init(text: delta, status: .inProgress))
                    )),
                    .finishEntry(id: entryID)
                ]
                return result
            }

        case .itemStarted(let tid, let itemID, let kind, let title) where tid == threadId:
            var result = closeStreamingRun()
            guard itemEntries[itemID] == nil else { return result }
            let entryID = makeID(scope: "item", providerID: itemID)
            let blockID = childID(of: entryID, key: "content")
            itemEntries[itemID] = entryID
            itemBlocks[itemID] = blockID
            let block = structuredBlock(id: blockID, kind: kind, title: title)
            compatibilityIDs[entryID] = itemID
            // Match the compatibility model's activity semantics: every
            // structured item except an error is active until completion.
            if kind != .error { activeItemIDs.insert(itemID) }
            // Diff/error payloads do not carry lifecycle state in AgentContent;
            // every other mapped payload does and receives completeBlock.
            if kind != .fileChange && kind != .error { statusableItems.insert(itemID) }
            result += [
                .beginEntry(id: entryID, role: role(for: kind), provenance: .providerItem(provider: "runtime", itemID: itemID)),
                .upsertStructured(entryID: entryID, block: block)
            ]
            return result

        case .itemCompleted(let tid, let itemID, _, let status) where tid == threadId:
            activeItemIDs.remove(itemID)
            completedStatuses[itemID] = status
            guard let entryID = itemEntries[itemID] else { return [] }
            var result: [AgentDocumentMutation] = []
            if statusableItems.contains(itemID), let blockID = itemBlocks[itemID] {
                result.append(.completeBlock(id: blockID, status: semanticStatus(status)))
            }
            result.append(.finishEntry(id: entryID))
            return result

        case let .childAgentSpawned(tid, childAgentID, parentAgentID, displayName, sourceItemID, provider, spawnedAt) where tid == threadId:
            guard referencedAgentIDs.insert(childAgentID).inserted else { return [] }
            var result = closeStreamingRun()
            let entryID = makeID(scope: "agent-reference", providerID: childAgentID.uuidString)
            let blockID = childID(of: entryID, key: "content")
            result += [
                .beginEntry(
                    id: entryID,
                    role: .system,
                    provenance: .providerItem(provider: provider, itemID: sourceItemID)
                ),
                .upsertStructured(entryID: entryID, block: AgentBlock(
                    id: blockID,
                    kind: .agentReference,
                    payload: .agentReference(.init(
                        agentID: childAgentID,
                        parentAgentID: parentAgentID,
                        displayNameAtSpawn: displayName,
                        spawnedAt: spawnedAt,
                        sourceItemID: sourceItemID,
                        provider: provider
                    ))
                )),
                .finishEntry(id: entryID)
            ]
            return result

        case .turnCompleted(let tid, let turnID, _, let errorMessage) where tid == threadId:
            var result = closeStreamingRun()
            if let errorMessage, !errorMessage.isEmpty {
                result += errorMutations(message: errorMessage, provenanceID: turnID, suffix: "turn-error")
            }
            return result

        case .runtimeError(let tid, let message) where tid == nil || tid == threadId:
            var result = closeStreamingRun()
            runtimeErrorSequence += 1
            result += errorMutations(message: message, provenanceID: tid, suffix: "runtime-error:\(runtimeErrorSequence)")
            return result

        // P5.4: explicit provider-enforced requests are semantic transcript
        // blocks owned here, never a parallel projection inside a tile. Prompt
        // and choices come only from the compiled event/decision vocabulary; a
        // request resolves only on a real resolution event.
        case .requestOpened(let tid, let requestID, let kind) where tid == threadId:
            return openRequestMutations(
                requestID: requestID,
                blockKind: .approval,
                payloadKind: AgentBlockPayload.approval,
                prompt: kind.compiledRequestPrompt,
                choices: ApprovalDecision.compiledChoices
            )

        case .userInputRequested(let tid, let requestID, let questions) where tid == threadId:
            let prompt = questions.map(\.prompt).filter { !$0.isEmpty }.joined(separator: " ")
            return openRequestMutations(
                requestID: requestID,
                blockKind: .question,
                payloadKind: AgentBlockPayload.question,
                prompt: prompt.isEmpty ? "Provider requested input" : prompt,
                choices: []
            )

        case .requestResolved(let tid, let requestID, let decision) where tid == threadId:
            guard let entryID = requestEntries[requestID], let blockID = requestBlocks[requestID] else { return [] }
            let declined = decision == ApprovalDecision.decline.rawValue
                || decision == ApprovalDecision.cancel.rawValue
            return [
                .completeBlock(id: blockID, status: declined ? .cancelled : .completed),
                .finishEntry(id: entryID)
            ]

        case .userInputResolved(let tid, let requestID) where tid == threadId:
            guard let entryID = requestEntries[requestID], let blockID = requestBlocks[requestID] else { return [] }
            return [
                .completeBlock(id: blockID, status: .completed),
                .finishEntry(id: entryID)
            ]

        default:
            return []
        }
    }

    private mutating func openRequestMutations(
        requestID: String,
        blockKind: AgentBlockKind,
        payloadKind: (AgentRequestPayload) -> AgentBlockPayload,
        prompt: String,
        choices: [String]
    ) -> [AgentDocumentMutation] {
        var result = closeStreamingRun()
        guard requestEntries[requestID] == nil else { return result }
        let entryID = makeID(scope: "request", providerID: requestID)
        let blockID = childID(of: entryID, key: "request")
        requestEntries[requestID] = entryID
        requestBlocks[requestID] = blockID
        compatibilityIDs[entryID] = requestID
        result += [
            .beginEntry(id: entryID, role: .system, provenance: .providerItem(provider: "runtime", itemID: requestID)),
            .upsertStructured(entryID: entryID, block: AgentBlock(
                id: blockID,
                kind: blockKind,
                payload: payloadKind(AgentRequestPayload(
                    requestID: requestID,
                    prompt: [.text(prompt)],
                    status: .inProgress,
                    choices: choices
                ))
            ))
        ]
        return result
    }

    /// Finds the transcript entry that carries one explicit provider request, so
    /// a needs-attention affordance can reveal the real block instead of an
    /// orphan label. Nil means the request never reached this projection.
    public func requestEntryID(for requestID: String) -> AgentNodeID? {
        requestEntries[requestID]
    }

    public mutating func ingest(_ event: AgentRuntimeEvent) {
        events.append(event)
        if events.count > Self.eventWindow { events.removeFirst(events.count - Self.eventWindow) }
        currentStatus = deriveAgentStatus(
            signals: deriveStatusSignals(from: events, threadId: threadId, engineStatus: .idle)
        )
        for mutation in mutations(for: event) {
            do { try reducer.apply(mutation) }
            catch { rejectedMutationCount += 1 }
        }
    }

    /// Adds a locally submitted prompt without forging a provider event.
    ///
    /// The caller owns `id` (normally from its submission record), so retries
    /// are idempotent and inserting unrelated transcript entries cannot change
    /// prompt identity. A local entry is assembled from several reducer
    /// mutations; each returned patch is therefore one real version step and
    /// must be applied in order by an incremental consumer.
    @discardableResult
    public mutating func appendUserPrompt(
        id: AgentNodeID,
        prompt: AgentPrompt
    ) throws -> [AgentDocumentPatch] {
        guard !document.entries.contains(where: { $0.id == id }) else { return [] }

        var patches = try applyReturningPatches(closeStreamingRun())
        compatibilityIDs[id] = id.rawValue
        var mutations: [AgentDocumentMutation] = [
            .beginEntry(id: id, role: .user, provenance: .localPrompt(promptID: id.rawValue))
        ]
        // Attachment blocks precede prose so the sent turn preserves the
        // composer's attachment-above-editor hierarchy. Only path-free metadata
        // enters the semantic document; local URLs remain transport capabilities.
        if !prompt.fileReferences.isEmpty {
            let blockID = childID(of: id, key: "file-references")
            mutations.append(.upsertStructured(entryID: id, block: AgentBlock(
                id: blockID,
                kind: .fileReferences,
                payload: .fileReferences(.init(files: prompt.fileReferences.map(\.transcriptMetadata)))
            )))
        }
        if !prompt.imageAttachments.isEmpty {
            let blockID = childID(of: id, key: "images")
            mutations.append(.upsertStructured(entryID: id, block: AgentBlock(
                id: blockID,
                kind: .imageGallery,
                payload: .imageGallery(.init(images: prompt.imageAttachments.map(\.imagePayload)))
            )))
        }
        if !prompt.text.isEmpty || (prompt.imageAttachments.isEmpty && prompt.fileReferences.isEmpty) {
            let blockID = childID(of: id, key: "prompt")
            mutations.append(.upsertStructured(entryID: id, block: AgentBlock(
                id: blockID, kind: .paragraph, payload: .paragraph([.text(prompt.text)])
            )))
        }
        mutations.append(.finishEntry(id: id))
        patches += try applyReturningPatches(mutations)
        return patches
    }

    public mutating func appendUserPrompt(
        id: AgentNodeID,
        text: String
    ) throws -> [AgentDocumentPatch] {
        try appendUserPrompt(id: id, prompt: AgentPrompt(text))
    }

    /// Adds an idempotent Continuum-authored notice. The heading child keeps
    /// the title semantic while the notice payload remains the compatibility
    /// body projected by the temporary card path.
    @discardableResult
    public mutating func appendNotice(
        id: AgentNodeID,
        title: String,
        body: String
    ) throws -> [AgentDocumentPatch] {
        guard !document.entries.contains(where: { $0.id == id }) else { return [] }

        var patches = try applyReturningPatches(closeStreamingRun())
        compatibilityIDs[id] = id.rawValue
        let blockID = childID(of: id, key: "notice")
        let titleID = childID(of: blockID, key: "title")
        patches += try applyReturningPatches([
            .beginEntry(id: id, role: .system, provenance: .localNotice(reason: id.rawValue)),
            .upsertStructured(entryID: id, block: AgentBlock(
                id: blockID,
                kind: .notice,
                payload: .notice(.init(message: [.text(body)])),
                children: [AgentBlock(
                    id: titleID,
                    kind: .heading,
                    payload: .heading(level: 3, content: [.text(title)])
                )]
            )),
            .finishEntry(id: id)
        ])
        return patches
    }

    // Compatibility APIs remain until the card projection is removed.
    public mutating func appendUserPrompt(_ text: String) {
        localSequence += 1
        let entryID = makeID(scope: "local-prompt", providerID: String(localSequence))
        let compatibilityID = "user-\(document.entries.count + 1)"
        do {
            _ = try appendUserPrompt(id: entryID, text: text)
            compatibilityIDs[entryID] = compatibilityID
        } catch {
            rejectedMutationCount += 1
        }
    }

    public mutating func appendNotice(id: String, title: String, text: String) {
        let entryID = makeID(scope: "notice", providerID: id)
        do {
            _ = try appendNotice(id: entryID, title: title, body: text)
            compatibilityIDs[entryID] = id
        } catch {
            rejectedMutationCount += 1
        }
    }

    private mutating func markupMutations(
        turnID: String,
        kind: ContentStreamKind,
        delta: String
    ) -> [AgentDocumentMutation] {
        if openStream?.turnID == turnID, openStream?.kind == kind {
            openStream!.buffer.append(delta)
            openStream!.scheduler.requestParse()
            return scheduledMarkupMutationsForOpenStream()
        }
        var result = closeStreamingRun()
        let entryID = makeID(scope: "turn", providerID: turnID, suffix: "\(kind.rawValue):\(nextRun(in: turnID))")
        compatibilityIDs[entryID] = "\(kind == .assistant ? "assistant" : "reasoning")-\(document.entries.count + result.beginEntryCount + 1)"
        var buffer = StreamingMarkupBuffer()
        buffer.append(delta)
        openStream = OpenStream(
            turnID: turnID,
            kind: kind,
            entryID: entryID,
            buffer: buffer,
            scheduler: StreamingMarkupParseScheduler(maximumParsesPerSecond: 30)
        )
        openStream!.scheduler.requestParse()
        result += [
            .beginEntry(
                id: entryID,
                role: kind == .assistant ? .assistant : .reasoning,
                provenance: .providerItem(provider: "runtime", itemID: turnID)
            )
        ]
        result += scheduledMarkupMutationsForOpenStream()
        return result
    }

    private mutating func scheduledMarkupMutationsForOpenStream() -> [AgentDocumentMutation] {
        guard openStream?.scheduler.shouldParse(now: monotonicNow()) == true else { return [] }
        return parsedMarkupMutationsForOpenStream()
    }

    private mutating func parsedMarkupMutationsForOpenStream() -> [AgentDocumentMutation] {
        guard let stream = openStream else { return [] }
        streamingMarkupParseCount += 1
        let previous = document.entries.first(where: { $0.id == stream.entryID })?.blocks ?? []
        let parse = markupParser.parse(stream.buffer.source, entryID: stream.entryID, previous: previous)
        return [.replaceMarkup(entryID: stream.entryID, blocks: parse.blocks)]
    }

    private mutating func archiveRawMarkupSourceForOpenStream() {
        guard let stream = openStream, rawMarkupSourcesByEntryID[stream.entryID] == nil else { return }
        rawMarkupSourcesByEntryID[stream.entryID] = stream.buffer.source
    }

    private mutating func closeStreamingRun() -> [AgentDocumentMutation] {
        guard openStream != nil else { return [] }
        var result: [AgentDocumentMutation] = []
        if openStream?.scheduler.flush() == true {
            result += parsedMarkupMutationsForOpenStream()
        }
        archiveRawMarkupSourceForOpenStream()
        let entryID = openStream!.entryID
        openStream = nil
        result.append(.finishEntry(id: entryID))
        return result
    }

    private mutating func nextRun(in turnID: String) -> Int {
        let next = (runCountsByTurn[turnID] ?? 0) + 1
        runCountsByTurn[turnID] = next
        return next
    }

    private func structuredBlock(id: AgentNodeID, kind: ItemKind, title: String?) -> AgentBlock {
        let label = title ?? kind.rawValue
        switch kind {
        case .plan:
            return AgentBlock(id: id, kind: .plan, payload: .plan(.init(title: title, status: .inProgress)))
        case .fileChange:
            // Runtime `title` is the provider's explicit safe display label.
            // Keep compatibility text, but never derive file names/counts by
            // parsing it; richer provider events can populate those fields.
            return AgentBlock(
                id: id,
                kind: .diff,
                payload: .diff(.init(text: label, summary: title))
            )
        case .error:
            return AgentBlock(id: id, kind: .error, payload: .error(.init(message: label)))
        default:
            return AgentBlock(id: id, kind: .toolCall, payload: .toolCall(.init(
                name: label, summary: nil, arguments: nil, status: .inProgress
            )))
        }
    }

    private func role(for kind: ItemKind) -> AgentEntryRole {
        switch kind {
        case .assistantMessage: return .assistant
        case .reasoning: return .reasoning
        default: return .system
        }
    }

    private mutating func errorMutations(message: String, provenanceID: String?, suffix: String) -> [AgentDocumentMutation] {
        let entryID = makeID(scope: "error", providerID: provenanceID ?? threadId, suffix: suffix)
        let blockID = childID(of: entryID, key: "error")
        compatibilityIDs[entryID] = "error-\(document.entries.count + 1)"
        return [
            .beginEntry(id: entryID, role: .system, provenance: .providerItem(provider: "runtime", itemID: provenanceID)),
            .upsertStructured(entryID: entryID, block: AgentBlock(
                id: blockID, kind: .error, payload: .error(.init(message: message))
            )),
            .finishEntry(id: entryID)
        ]
    }

    private func semanticStatus(_ status: ItemStatus) -> AgentItemStatus {
        switch status {
        case .inProgress: return .inProgress
        case .completed: return .completed
        case .failed: return .failed
        case .declined: return .cancelled
        }
    }

    private func makeID(scope: String, providerID: String, suffix: String? = nil) -> AgentNodeID {
        let encoded = Data(providerID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let bounded = encoded.utf8.count <= 360 ? encoded : stableDigest(providerID)
        let raw = [scope, bounded, suffix].compactMap { $0 }.joined(separator: ":")
        return AgentNodeID(rawValue: raw)!
    }

    private func childID(of entryID: AgentNodeID, key: String) -> AgentNodeID {
        entryID.childID(stableKey: key) ?? AgentNodeID(rawValue: "child:\(stableDigest(entryID.rawValue + key))")!
    }

    private func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private mutating func apply(_ mutations: [AgentDocumentMutation]) {
        for mutation in mutations {
            do { try reducer.apply(mutation) }
            catch { rejectedMutationCount += 1 }
        }
    }

    private mutating func applyReturningPatches(
        _ mutations: [AgentDocumentMutation]
    ) throws -> [AgentDocumentPatch] {
        var patches: [AgentDocumentPatch] = []
        for mutation in mutations {
            patches.append(try reducer.apply(mutation))
        }
        return patches
    }
}

extension AgentTranscriptProjection: AgentTranscriptProjecting {
    public var compatibilityRows: [AgentTranscriptCompatibilityRow] {
        // Request entries are v2 semantic blocks (P5.4). The compatibility card
        // stack has its own approval dock and user-input card UI for the same
        // events, so projecting them here would duplicate the request as an
        // empty legacy card and move blessed legacy baselines.
        let markupSources = compatibilityMarkupSourcesByEntryID
        return document.entries.filter { entry in
            switch entry.blocks.first?.kind {
            case .approval?, .question?: return false
            default: return true
            }
        }.map { entry in
            AgentTranscriptCompatibilityRow(
                id: compatibilityIDs[entry.id] ?? entry.id.rawValue,
                kind: compatibilityKind(entry),
                body: compatibilityBody(entry, markupSources: markupSources),
                status: compatibilityStatus(entry)
            )
        }
    }

    private func compatibilityKind(_ entry: AgentEntry) -> String {
        guard let block = entry.blocks.first else {
            return entry.role == .user ? ManagedTranscriptCardKind.userMessage.rawValue : ManagedTranscriptCardKind.message.rawValue
        }
        switch block.kind {
        case .toolCall, .commandOutput: return ManagedTranscriptCardKind.toolCall.rawValue
        case .plan: return ManagedTranscriptCardKind.plan.rawValue
        case .diff: return ManagedTranscriptCardKind.diff.rawValue
        case .error: return ManagedTranscriptCardKind.error.rawValue
        default: return entry.role == .user ? ManagedTranscriptCardKind.userMessage.rawValue : ManagedTranscriptCardKind.message.rawValue
        }
    }

    private func compatibilityBody(
        _ entry: AgentEntry,
        markupSources: [AgentNodeID: String]
    ) -> String {
        if let rawMarkup = markupSources[entry.id] { return rawMarkup }
        return entry.blocks.map { block in
            switch block.payload {
            case .paragraph(let inlines):
                return plainText(inlines)
            case .notice(let notice):
                return plainText(notice.message)
            case .commandOutput(let output): return output.text
            case .error(let error):
                if case .providerItem(_, let itemID?) = entry.provenance, itemEntries[itemID] == entry.id {
                    return ""
                }
                return error.message
            default: return ""
            }
        }.joined()
    }

    private func compatibilityStatus(_ entry: AgentEntry) -> ItemStatus? {
        guard case .providerItem(_, let itemID?) = entry.provenance else { return nil }
        if let completed = completedStatuses[itemID] { return completed }
        if itemEntries[itemID] == entry.id { return .inProgress }
        if entry.blocks.first?.kind == .commandOutput { return .inProgress }
        return nil
    }

    private func plainText(_ inlines: [AgentInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text), .code(let text): return text
            case .emphasis(let children), .strong(let children): return plainText(children)
            case .link(_, _, let children): return plainText(children)
            case .softBreak: return " "
            case .hardBreak: return "\n"
            }
        }.joined()
    }
}

public extension ApprovalKind {
    /// One compiled prompt per request kind; never derived from prose. Shared by
    /// the transcript projection and the supervisor's turn facts so the revealed
    /// block and the needs-action state can never describe different requests.
    var compiledRequestPrompt: String {
        switch self {
        case .commandExecutionApproval: return "Allow the requested command?"
        case .applyPatchApproval: return "Allow the requested patch?"
        case .toolUserInput: return "The provider requested a decision"
        }
    }
}

public extension ApprovalDecision {
    /// The compiled decision vocabulary — the only choices a request surface may
    /// advertise. No transport-free path may resolve one locally.
    static let compiledChoices = [
        ApprovalDecision.accept.rawValue,
        ApprovalDecision.acceptForSession.rawValue,
        ApprovalDecision.decline.rawValue,
        ApprovalDecision.cancel.rawValue,
    ]
}

private extension Array where Element == AgentDocumentMutation {
    var beginEntryCount: Int {
        reduce(into: 0) { count, mutation in
            if case .beginEntry = mutation { count += 1 }
        }
    }
}
