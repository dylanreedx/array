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
    private let timeToLive: TimeInterval?
    private let clock: @Sendable () -> Date

    /// Called after a store snapshot lands, so the view can re-present rows.
    var onRefresh: (() -> Void)?

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
            Task { [weak self, store] in
                for start in starts { _ = await store.recordStart(start) }
                self?.refresh()
            }
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
            Task { [weak self, store] in
                _ = await store.recordEnd(AgentToolDetailEnd(
                    identity: identity, output: end?.outputPreview, status: mapped, exitCode: end?.exitCode,
                    endedAt: end?.observedAt, shellOutcome: end?.shellOutcome, reportedDuration: end?.reportedDuration))
                self?.refresh()
            }
        case let .turnCompleted(threadID, _, outcome, _):
            guard let scope = activeScope, scope.threadID == threadID else { break }
            let swept = identitiesAwaitingEnd.filter { $0.scope == scope }
            guard !swept.isEmpty else { break }
            identitiesAwaitingEnd.subtract(swept)
            let status: AgentItemStatus = outcome == .completed ? .completed : .interrupted
            Task { [weak self, store] in
                for identity in swept.sorted(by: { $0.providerItemID.rawValue < $1.providerItemID.rawValue }) {
                    _ = await store.recordEnd(AgentToolDetailEnd(identity: identity, status: status))
                }
                self?.refresh()
            }
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
        Task { [weak self, store] in
            _ = await store.recordStart(start)
            self?.refresh()
        }
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

    private func refresh() {
        guard let store else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self, store] in
            let records = await store.allDetails()
            guard !Task.isCancelled, let self else { return }
            self.details = Dictionary(uniqueKeysWithValues: records.map { ($0.identity, $0) })
            self.presentedCache.removeAll()
            self.onRefresh?()
        }
    }

    func qaWaitForRefresh() async { await refreshTask?.value }

    // MARK: Presentation

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

    /// `AgentTranscriptListView.presentedToolBlock`, for one block of `entry`.
    func presented(_ block: AgentBlock, in entry: AgentEntry) -> AgentBlock {
        switch block.payload {
        case .toolCall, .diff: break
        default: return block
        }
        guard let identity = key(for: entry), let detail = details[identity], detail.identity == identity else { return block }
        if let timeToLive, timeToLive <= 0 || clock().timeIntervalSince(detail.updatedAt) >= timeToLive { return block }
        // Every rebuild presents every tool row, and presenting is redaction and
        // string work; a transcript's worth of it ran on each update and at every
        // turn end. The result depends on the block and its detail record only.
        if let cached = presentedCache[block.id], cached.revision == block.revision, cached.identity == identity {
            return cached.block
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
            return block
        }
        presentedCache[block.id] = (block.revision, identity, presented)
        qaPresentationCount += 1
        return presented
    }

    /// Tool and diff blocks presented from their detail records, not the cache.
    private(set) var qaPresentationCount = 0

    /// Presented tool and diff blocks, emptied whenever detail records land.
    private var presentedCache: [AgentNodeID: (revision: UInt64, identity: AgentToolDetailKey, block: AgentBlock)] = [:]
}
