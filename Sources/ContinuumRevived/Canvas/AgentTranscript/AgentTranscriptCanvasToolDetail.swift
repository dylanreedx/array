import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// The host-local tool detail behind `AgentTranscriptCanvasView`: runtime capture
/// into the `AgentToolDetailStore`, and the presented copy of tool and diff blocks
/// (action sentence, duration, shell, output, changed files).
///
/// A transcription of `AgentTranscriptListView`'s capture adapter
/// (`captureRuntimeEvent`, `captureRuntimeObservation`, `detailStart`,
/// `bufferEndDetail`) and of `presentedToolBlock`, minus cluster membership and
/// chip runs, which the canvas renderer does not group. Kept a copy rather than a
/// shared extraction so the shipped list's behaviour cannot move while the canvas
/// renderer is behind its switch; fold the two together when the switch goes.
@MainActor
final class AgentTranscriptCanvasToolDetail {
    private let store: AgentToolDetailStore?
    private var agentID: AgentID?
    private var activeScope: AgentToolDetailScope?
    private var runtimeIdentities: Set<AgentToolDetailKey> = []
    private var identitiesAwaitingEnd: Set<AgentToolDetailKey> = []
    private var pendingObservations: [AgentToolDetailKey: [AgentRuntimeObservation]] = [:]
    private var pendingEndDetails: [AgentToolDetailKey: AgentToolDetailObservation] = [:]
    private var runtimeTitles: [AgentToolDetailKey: String] = [:]
    private var identityByEntryID: [AgentNodeID: AgentToolDetailKey] = [:]
    private var details: [AgentToolDetailKey: AgentToolDetailRecord] = [:]
    private var refreshTask: Task<Void, Never>?
    private var pendingWrites: [AgentToolDetailWrite] = []
    /// The store revision `details` reflects.
    private var storeRevision: UInt64 = 0
    private let timeToLive: TimeInterval?
    private let clock: @Sendable () -> Date

    /// Called after a store snapshot lands, so the view can re-present rows.
    var onRefresh: (() -> Void)?
    var fallbackPresentation: ((AgentBlock) -> AgentBlock?)?

    init(store: AgentToolDetailStore?) {
        self.store = store
        if let store {
            timeToLive = store.timeToLive
            clock = store.currentDate
        } else {
            timeToLive = nil
            clock = { Date() }
        }
    }

    func bind(agentID: AgentID?) {
        self.agentID = agentID
        activeScope = nil
        runtimeIdentities.removeAll()
        pendingObservations.removeAll()
        pendingEndDetails.removeAll()
        runtimeTitles.removeAll()
    }

    func bindIdentity(_ identity: AgentToolDetailKey, to entryID: AgentNodeID) -> Bool {
        if let agentID, identity.scope.agentID != agentID.rawValue.uuidString { return false }
        guard let existing = identityByEntryID[entryID] else {
            identityByEntryID[entryID] = identity
            return true
        }
        return existing == identity
    }

    // MARK: Capture

    @discardableResult
    func captureRuntimeEvent(_ event: AgentRuntimeEvent) -> AgentToolDetailKey? {
        guard let store else { return nil }
        switch event {
        case let .turnStarted(threadID, turnID):
            let scope = agentID.flatMap {
                AgentToolDetailScope(agentID: $0.rawValue.uuidString, threadID: threadID, turnID: turnID, provider: "runtime")
            }
            activeScope = scope
            pendingObservations = pendingObservations.filter { $0.key.scope == scope }
            pendingEndDetails = pendingEndDetails.filter { $0.key.scope == scope }
            runtimeTitles = runtimeTitles.filter { $0.key.scope == scope }
            return nil
        case let .itemStarted(threadID, itemID, kind, title):
            guard AgentToolDetailPolicy.carriesHostLocalDetail(kind),
                  let providerID = AgentToolDetailID(itemID),
                  let scope = activeScope, scope.threadID == threadID else { return nil }
            let identity = AgentToolDetailKey(scope: scope, providerItemID: providerID)
            runtimeIdentities.insert(identity)
            identitiesAwaitingEnd.insert(identity)
            let resolvedTitle = title ?? "Tool"
            runtimeTitles[identity] = resolvedTitle
            let pending = pendingObservations.removeValue(forKey: identity) ?? []
            let starts = [AgentToolDetailStart(identity: identity, toolName: resolvedTitle)]
                + pending.compactMap { detailStart(for: identity, observation: $0, title: resolvedTitle) }
            for case let .toolDetail(_, detail) in pending where detail.phase == .ended {
                bufferEndDetail(detail, identity: identity)
            }
            record(starts.map { .start($0) })
            return identity
        case let .itemCompleted(threadID, itemID, kind, status):
            guard AgentToolDetailPolicy.carriesHostLocalDetail(kind),
                  let providerID = AgentToolDetailID(itemID),
                  let scope = activeScope, scope.threadID == threadID else { return nil }
            let identity = AgentToolDetailKey(scope: scope, providerItemID: providerID)
            guard runtimeIdentities.contains(identity) else { return nil }
            let mapped: AgentItemStatus = status == .failed ? .failed : (status == .declined ? .cancelled : .completed)
            let end = pendingEndDetails.removeValue(forKey: identity)
            identitiesAwaitingEnd.remove(identity)
            record([.end(AgentToolDetailEnd(
                identity: identity, output: end?.outputPreview, status: mapped, exitCode: end?.exitCode,
                endedAt: end?.observedAt, shellOutcome: end?.shellOutcome, reportedDuration: end?.reportedDuration))])
        case let .turnCompleted(threadID, _, outcome, _):
            guard let scope = activeScope, scope.threadID == threadID else { break }
            let swept = identitiesAwaitingEnd.filter { $0.scope == scope }
            guard !swept.isEmpty else { break }
            identitiesAwaitingEnd.subtract(swept)
            let status: AgentItemStatus = outcome == .completed ? .completed : .interrupted
            record(swept.sorted(by: { $0.providerItemID.rawValue < $1.providerItemID.rawValue })
                .map { .end(AgentToolDetailEnd(identity: $0, status: status)) })
        default:
            break
        }
        return nil
    }

    func captureRuntimeObservation(_ observation: AgentRuntimeObservation) {
        guard let store else { return }
        let itemID: String
        switch observation {
        case let .toolActivity(id, _): itemID = id
        case let .toolDetail(id, _): itemID = id
        default: return
        }
        guard let providerID = AgentToolDetailID(itemID), let scope = activeScope else { return }
        let identity = AgentToolDetailKey(scope: scope, providerItemID: providerID)
        guard runtimeIdentities.contains(identity) else {
            pendingObservations[identity, default: []].append(observation)
            return
        }
        if case let .toolDetail(_, detail) = observation, detail.phase == .ended {
            bufferEndDetail(detail, identity: identity)
            return
        }
        guard let start = detailStart(for: identity, observation: observation, title: runtimeTitles[identity] ?? "Tool") else { return }
        record([.start(start)])
    }

    private func detailStart(for identity: AgentToolDetailKey, observation: AgentRuntimeObservation,
                             title: String) -> AgentToolDetailStart? {
        switch observation {
        case let .toolActivity(_, activity):
            return AgentToolDetailStart(identity: identity, toolName: title,
                                        affectedFiles: activity.targetPath.map { [$0] } ?? [])
        case let .toolDetail(_, detail) where detail.phase == .started:
            return AgentToolDetailStart(
                identity: identity, toolName: detail.toolName ?? title,
                arguments: detail.fields.map { AgentToolDetailField(key: $0.key, value: $0.value) },
                fileChanges: detail.fileChanges, parentItemID: detail.parentItemID, startedAt: detail.observedAt)
        default:
            return nil
        }
    }

    private func bufferEndDetail(_ detail: AgentToolDetailObservation, identity: AgentToolDetailKey) {
        guard let existing = pendingEndDetails[identity] else {
            pendingEndDetails[identity] = detail
            return
        }
        pendingEndDetails[identity] = AgentToolDetailObservation(
            phase: .ended,
            toolName: detail.toolName ?? existing.toolName,
            fields: detail.fields.isEmpty ? existing.fields : detail.fields,
            outputPreview: detail.outputPreview ?? existing.outputPreview,
            exitCode: detail.exitCode ?? existing.exitCode,
            fileChanges: detail.fileChanges.isEmpty ? existing.fileChanges : detail.fileChanges,
            parentItemID: detail.parentItemID ?? existing.parentItemID,
            shellOutcome: detail.shellOutcome ?? existing.shellOutcome,
            reportedDuration: detail.reportedDuration ?? existing.reportedDuration,
            observedAt: detail.observedAt)
    }

    /// Writes to the store in the order they were captured, and applies what
    /// changed there since the last batch. One drain runs at a time and takes
    /// everything queued behind it, so a burst of tool events costs the main
    /// actor a hop per batch and the records that changed, not a task and a
    /// full read per event. Every event reading every record, with each
    /// cancelled read's snapshot freed here, kept main busy for seconds.
    private func record(_ writes: [AgentToolDetailWrite]) {
        guard store != nil, !writes.isEmpty else { return }
        pendingWrites += writes
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while let self, !self.pendingWrites.isEmpty {
                let batch = self.pendingWrites
                self.pendingWrites = []
                await self.write(batch)
            }
            self?.refreshTask = nil
        }
    }

    private func write(_ batch: [AgentToolDetailWrite]) async {
        guard let store else { return }
        let changes = await store.record(batch, changesSince: storeRevision)
        storeRevision = changes.revision
        guard !changes.isEmpty else { return }
        var touched = Set(changes.removed)
        for key in changes.removed { details[key] = nil }
        for record in changes.changed { details[record.identity] = record; touched.insert(record.identity) }
        // A presentation depends on its block and its record only.
        presentedCache = presentedCache.filter { !touched.contains($0.value.identity) }
        presentationGeneration &+= 1
        onRefresh?()
    }

    /// Returns once every refresh requested so far has landed.
    func qaWaitForRefresh() async {
        while let running = refreshTask { await running.value }
    }

    /// Witness only: the records this capture holds, and its store's own.
    func qaDetailsMatchStore() async -> (held: Int, stored: Int, equal: Bool) {
        guard let store else { return (details.count, 0, details.isEmpty) }
        let stored = Dictionary(uniqueKeysWithValues: await store.allDetails().map { ($0.identity, $0) })
        return (details.count, stored.count, stored == details)
    }

    // MARK: Presentation

    /// `AgentTranscriptListView.presentedToolBlock`, for one block of `entry`.
    func presented(_ block: AgentBlock, in entry: AgentEntry) -> AgentBlock {
        switch presentation.present(block, in: entry) {
        case .unchanged: return block
        case .fallback: return fallbackPresentation?(block) ?? block
        case let .cached(presented): return presented
        case let .fresh(presented, cached):
            presentedCache[block.id] = cached
            qaPresentationCount += 1
            return presented
        }
    }

    /// Everything `presented` reads, frozen, so the shared-transcript publisher
    /// can present a whole document off the main actor. The fallback is not
    /// part of it: a frozen presentation reports `.fallback` and the caller
    /// decides. `generation` names the detail records it was taken from.
    var presentation: Presentation {
        Presentation(agentID: agentID, identityByEntryID: identityByEntryID, details: details,
                     timeToLive: timeToLive, clock: clock, cache: presentedCache, generation: presentationGeneration)
    }

    /// Keeps blocks an off-main presentation produced, unless detail records
    /// landed since it was taken (they would be stale).
    func adopt(_ fresh: [AgentNodeID: Presentation.Cached], from generation: UInt64) {
        guard generation == presentationGeneration, !fresh.isEmpty else { return }
        presentedCache.merge(fresh) { _, new in new }
        qaPresentationCount += fresh.count
    }

    struct Presentation: Sendable {
        typealias Cached = (revision: UInt64, identity: AgentToolDetailKey, block: AgentBlock)
        enum Outcome {
            /// Not a tool or diff block.
            case unchanged
            /// No live detail record: the caller's fallback, else the block.
            case fallback
            case cached(AgentBlock)
            /// Presented now from its detail record; cache it.
            case fresh(AgentBlock, Cached)
        }

        let agentID: AgentID?
        let identityByEntryID: [AgentNodeID: AgentToolDetailKey]
        let details: [AgentToolDetailKey: AgentToolDetailRecord]
        let timeToLive: TimeInterval?
        let clock: @Sendable () -> Date
        let cache: [AgentNodeID: Cached]
        let generation: UInt64

        private func key(for entry: AgentEntry) -> AgentToolDetailKey? {
            guard case let .providerItem(provider, itemID?) = entry.provenance,
                  let itemID = AgentToolDetailID(itemID),
                  let candidate = identityByEntryID[entry.id],
                  candidate.providerItemID == itemID,
                  agentID == nil || candidate.scope.agentID == agentID?.rawValue.uuidString,
                  candidate.scope.provider == provider
            else { return nil }
            return candidate
        }

        func present(_ block: AgentBlock, in entry: AgentEntry) -> Outcome {
            switch block.payload {
            case .toolCall, .diff: break
            default: return .unchanged
            }
            guard let identity = key(for: entry), let detail = details[identity], detail.identity == identity else {
                return .fallback
            }
            if let timeToLive, timeToLive <= 0 || clock().timeIntervalSince(detail.updatedAt) >= timeToLive {
                return .fallback
            }
            // Every rebuild presents every tool row, and presenting is redaction and
            // string work; a transcript's worth of it ran on each update and at every
            // turn end. The result depends on the block and its detail record only.
            if let cached = cache[block.id], cached.revision == block.revision, cached.identity == identity {
                return .cached(cached.block)
            }
            var presented = block
            switch block.payload {
            case var .toolCall(payload):
                let collapsed = AgentToolDetailPresenter.collapsed(detail)
                payload.presentedToolNameText = payload.name
                payload.name = collapsed.actionLine
                payload.summary = AgentToolDetailPresenter.observableDisclosureText(detail)
                payload.presentedTrailingDetailText = collapsed.durationText
                payload.presentedShell = AgentToolDetailPresenter.shellInvocation(detail)
                if let output = detail.output {
                    payload.presentedOutputText = output.text
                    var notes: [String] = []
                    if output.truncatedByBytes { notes.append("truncated by size") }
                    if output.truncatedByLines { notes.append("truncated by lines") }
                    if output.redacted { notes.append("redacted") }
                    payload.presentedOutputNote = notes.isEmpty ? nil : "Output \(notes.joined(separator: ", "))"
                }
                presented.payload = .toolCall(payload)
            case var .diff(payload):
                if payload.files.isEmpty { payload.files = AgentToolDetailPresenter.observableChangedFiles(detail) }
                payload.presentedFilesArePending = payload.files.isEmpty
                    && (detail.status == .inProgress || detail.status == .pending)
                presented.payload = .diff(payload)
            default:
                return .unchanged
            }
            return .fresh(presented, (block.revision, identity, presented))
        }
    }

    /// Tool and diff blocks presented from their detail records, not the cache.
    private(set) var qaPresentationCount = 0

    /// Presented tool and diff blocks, emptied whenever detail records land.
    private var presentedCache: [AgentNodeID: Presentation.Cached] = [:]
    /// Bumped whenever detail records land, so an off-main presentation taken
    /// before them is not adopted.
    private var presentationGeneration: UInt64 = 0
}
