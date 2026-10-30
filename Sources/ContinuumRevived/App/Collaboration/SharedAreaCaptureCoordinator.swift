import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// One deliberately opened review. Local source IDs and text remain here until
/// the confirmed portable projection is handed to the area's authority.
@MainActor
final class SharedAreaCaptureCoordinator {
    typealias Publication = SharedAreaPublication
    typealias Key = Publication.SourceKey
    typealias InventoryProvider = @MainActor () throws -> SharedAreaInventory.Snapshot
    typealias Submitter = @MainActor (Publication.Confirmed) async -> SharedAreaController.Submission

    enum State: Equatable { case reviewing, submitting, uncertain, published, cancelled }
    enum Failure: Error { case unavailableArea, sourceWorkspaceChanged, refreshRequired, deliveryPending, noSuchSource }

    let selection: Publication.Selection
    let controller: SharedAreaController
    let person: SharedArea.ID<SharedArea.Person>
    let host: SharedArea.ID<SharedArea.Host>
    let workspaceID: UUID
    private let inventoryProvider: InventoryProvider
    private let submitter: Submitter
    private var snapshot: SharedAreaInventory.Snapshot
    private(set) var review: Publication.Review
    private(set) var modes: [Key: SharedAreaInventory.Mode] = [:]
    private(set) var state: State = .reviewing
    private(set) var requiresRefresh = false
    private(set) var message = "Choose what to share for each note, managed agent, diff and file. Unsupported tiles are excluded."
    private(set) var pendingPublication: Publication.Confirmed?
    /// Off-main captures of diff/file tiles chosen as artifacts (COL-16).
    private(set) var drafts: [Key: SharedArtifactProducer.Draft] = [:]
    private(set) var artifactFailures: [Key: String] = [:]
    private(set) var capturing: Set<Key> = []
    private(set) var publishedArtifacts = 0
    private var captureGeneration = 0
    private let artifactProducer: SharedArtifactProducer
    var onChange: (() -> Void)?
    var onPublished: (() -> Void)?

    init(selection: Publication.Selection, controller: SharedAreaController,
         person: SharedArea.ID<SharedArea.Person>, host: SharedArea.ID<SharedArea.Host>,
         inventoryProvider: @escaping InventoryProvider, submitter: @escaping Submitter,
         artifactProducer: SharedArtifactProducer = .init()) throws {
        guard let document = controller.document else { throw Failure.unavailableArea }
        let initial = try inventoryProvider()
        self.selection = selection; self.controller = controller; self.person = person; self.host = host
        self.inventoryProvider = inventoryProvider; self.submitter = submitter; self.artifactProducer = artifactProducer
        snapshot = initial; workspaceID = initial.inventory.workspaceID
        review = try Publication.prepare(inventory: initial.inventory, selection: selection, choices: [],
            area: document.id, author: person, host: host, expectedRevision: document.revision)
    }

    var canEditReview: Bool { state == .reviewing && !requiresRefresh }
    var canConfirm: Bool { canEditReview && review.readyToConfirm && controller.canSubmit && capturing.isEmpty }
    /// An unknown request may close only after the exact command/bindings have
    /// reached durable storage. The workspace recovers it after relaunch.
    var canClose: Bool {
        guard state != .submitting else { return false }
        guard state == .uncertain else { return true }
        guard let operation = pendingPublication?.command.id else { return false }
        return controller.deliveryRecord(for: operation) != nil
    }
    var readyCount: Int { review.rows.filter { if case .ready = $0.disposition { return true }; return false }.count }
    var pendingCount: Int { review.rows.filter { $0.disposition == .needsReview }.count }
    var excludedCount: Int { review.rows.count - readyCount - pendingCount }

    func setMode(_ mode: SharedAreaInventory.Mode, for source: Key) throws {
        guard state == .reviewing else { throw Failure.deliveryPending }
        guard !requiresRefresh else { throw Failure.refreshRequired }
        guard review.rows.contains(where: { $0.source == source }) else { throw Failure.noSuchSource }
        let previous = modes
        modes[source] = mode
        drafts[source] = nil; artifactFailures[source] = nil
        do { review = try makeReview(snapshot) }
        catch { modes = previous; throw error }
        message = "Review the captured content and layout, then share. Source tiles and files stay on this Mac."
        if Self.isArtifact(mode) { startCapture([source]) }
        onChange?()
    }

    /// The source a key captures under its current mode, or nil.
    private func artifactSource(_ key: Key, in value: SharedAreaInventory.Snapshot) -> SharedArtifactSource? {
        guard let mode = modes[key], Self.isArtifact(mode), let source = value.artifactSources[key] else { return nil }
        if case let .diff(root, diff, _) = source { return .diff(root: root, source: diff, includeUntracked: mode == .artifactWithUntracked) }
        return source
    }
    static func isArtifact(_ mode: SharedAreaInventory.Mode) -> Bool { mode == .artifact || mode == .artifactWithUntracked }

    /// git runs off main. A newer mode change or refresh discards a late result.
    private func startCapture(_ keys: [Key]) {
        captureGeneration += 1
        let generation = captureGeneration
        var sources: [Key: SharedArtifactSource] = [:]
        for key in keys {
            if let source = artifactSource(key, in: snapshot) { sources[key] = source }
            else { artifactFailures[key] = "This tile's repository could not be resolved from this Mac." }
        }
        capturing.formUnion(sources.keys)
        captureTask = Task { [weak self, producer = artifactProducer] in
            let results = await SharedArtifactSource.drafts(sources, producer: producer)
            guard let self, generation == self.captureGeneration else { return }
            for (key, result) in results {
                capturing.remove(key)
                switch result {
                case .success(let draft): drafts[key] = draft
                case .failure(let error): artifactFailures[key] = Self.artifactMessage(error)
                }
            }
            if let fresh = try? makeReview(snapshot) { review = fresh }
            onChange?()
        }
    }
    private(set) var captureTask: Task<Void, Never>?
    func artifactSummary(_ key: Key) -> String? {
        if capturing.contains(key) { return "Capturing a snapshot of the current changes…" }
        if let failure = artifactFailures[key] { return failure }
        guard let draft = drafts[key] else { return nil }
        let included = draft.entries.filter { $0.coverage == .included }
        let excluded = draft.entries.filter { $0.coverage != .included }
        let d = draft.declaration
        var lines = [Self.rangeTitle(d) + " · \(included.count) included, \(included.reduce(0) { $0 + ($1.length ?? 0) }) bytes"]
        if !excluded.isEmpty { lines.append("Declared without content: " + excluded.map { "\($0.path) (\($0.coverage.rawValue))" }.joined(separator: ", ")) }
        if d.omittedChangedPaths > 0 { lines.append("\(d.omittedChangedPaths) other changed paths are not part of this snapshot") }
        if d.omittedUntrackedPaths > 0 { lines.append("\(d.omittedUntrackedPaths) untracked files are not included; their names are not shared") }
        lines.append("")
        lines += included.map { $0.path }
        return lines.joined(separator: "\n")
    }
    private static func rangeTitle(_ d: Collaboration.Artifact.Declaration) -> String {
        switch d.range {
        case .files: return "Saved file contents"
        case .workingTree: return d.includesUntracked ? "Working tree vs HEAD, with selected untracked files" : "Working tree vs HEAD (staged and unstaged)"
        case .staged: return "Staged changes"
        case .branch: return "Committed branch changes only"
        }
    }
    static func artifactMessage(_ error: any Error) -> String {
        switch error as? SharedArtifactProducer.Failure {
        case .notRepository?: return "This tile is not inside a git repository, so it cannot be captured."
        case .changedDuringCapture?: return "The files kept changing while being captured. Try again when they settle."
        case .tooLarge?, .tooManyEntries?: return "These changes are too large to share as one snapshot."
        case .unsupportedSource?: return "This diff shows a branch other than the checkout's current one, so it cannot be captured."
        default: return "The snapshot could not be captured. Your files are unchanged."
        }
    }

    /// This is a deliberate new review, with newly allocated portable IDs. It
    /// cannot replace the operation whose delivery is still unknown.
    func refreshReview() throws {
        guard state == .reviewing else { throw Failure.deliveryPending }
        let fresh = try inventoryProvider()
        guard fresh.inventory.workspaceID == workspaceID else { throw Failure.sourceWorkspaceChanged }
        let priorModes = modes
        let selected = try Publication.prepare(inventory: fresh.inventory, selection: selection, choices: [],
            area: review.manifest.area, author: person, host: host,
            expectedRevision: controller.document?.revision ?? review.manifest.expectedRevision)
        let selectedKeys = Set(selected.rows.map(\.source))
        modes = modes.filter { selectedKeys.contains($0.key) }
        do { review = try makeReview(fresh) }
        catch { modes = priorModes; throw error }
        snapshot = fresh; requiresRefresh = false; pendingPublication = nil
        drafts = [:]; artifactFailures = [:]; capturing = []
        let artifactKeys = modes.filter { Self.isArtifact($0.value) }.map(\.key)
        if !artifactKeys.isEmpty { review = try makeReview(fresh); startCapture(artifactKeys) }
        message = "The selection was read again. Review every included item before sharing."
        onChange?()
    }

    func cancel() {
        guard canClose else {
            message = "Check delivery before closing this review. The request may already have committed."
            onChange?(); return
        }
        state = .cancelled; onChange?()
    }

    func confirm() async {
        guard canConfirm else { return }
        let publication: Publication.Confirmed
        let captures: [Collaboration.Artifact.Capture]
        do {
            let fresh = try inventoryProvider()
            guard fresh.inventory.workspaceID == workspaceID else { throw Failure.sourceWorkspaceChanged }
            // Re-capture every artifact now: the bytes published must be the
            // bytes on disk at confirmation, and equal to what was reviewed.
            var sources: [Key: SharedArtifactSource] = [:]
            for key in modes.keys { if let source = artifactSource(key, in: fresh) { sources[key] = source } }
            var freshDrafts: [Key: SharedArtifactProducer.Draft] = [:]
            for (key, result) in await SharedArtifactSource.drafts(sources, producer: artifactProducer) {
                if case .success(let draft) = result { freshDrafts[key] = draft }
            }
            guard state == .reviewing else { return }
            publication = try Publication.confirm(review, expectedDigest: review.digest,
                inventory: fresh.inventory, choices: fresh.choices(for: modes, drafts: freshDrafts))
            // Each artifact's first revision, under the revision ID reserved at review.
            captures = try publication.artifacts.map { artifact in
                guard let draft = freshDrafts[artifact.source], draft.contentDigest == artifact.contentDigest else { throw Publication.Failure.reviewChanged }
                return try draft.capture(object: artifact.object, id: artifact.revision, parent: nil)
            }
        } catch {
            requiresRefresh = true
            message = Self.message(for: error)
            onChange?(); return
        }
        // Durable before anything is sent: an accepted arrangement can always
        // get these exact bytes, after a failed upload or a relaunch.
        do { try controller.stageArtifactUploads(captures, for: publication.command.id) }
        catch {
            message = "The snapshots could not be saved on this Mac. Nothing was sent."
            onChange?(); return
        }
        pendingPublication = publication
        await deliver(publication)
    }

    /// The identical command and binding IDs recover an uncertain receipt. No
    /// second capture, reallocation or automatic executable retry occurs here.
    func checkDelivery() async {
        guard state == .uncertain, let pendingPublication else { return }
        if controller.status != .connected {
            state = .submitting; message = "Reconnecting to check this request…"; onChange?()
            await controller.open()
            state = .uncertain
            guard controller.status == .connected else {
                message = "Delivery cannot be checked yet. Reconnect and check this same request again."
                onChange?(); return
            }
        }
        if controller.deliveryRecord(for: pendingPublication.command.id) != nil {
            state = .submitting; message = "Checking the saved request…"; onChange?()
            let result = await controller.retryPending(pendingPublication.command.id)
            await finishDelivery(result, wasUncertain: true)
        } else {
            await deliver(pendingPublication)
        }
    }

    private func deliver(_ publication: Publication.Confirmed) async {
        let wasUncertain = state == .uncertain
        state = .submitting; message = "Sharing the reviewed selection…"; onChange?()
        let result = await submitter(publication)
        await finishDelivery(result, wasUncertain: wasUncertain)
    }
    /// Uploads the staged first revisions. A failure leaves the shared item
    /// honest about having no revision yet; the controller retries the same
    /// bytes on reconnect and after a relaunch.
    private func publishArtifacts(_ publication: Publication.Confirmed) async -> String? {
        guard !publication.artifacts.isEmpty else { return nil }
        await controller.uploadStagedArtifacts()
        let waiting = Set(controller.stagedArtifactUploads.map(\.manifest.id))
        let failures = publication.artifacts.filter { waiting.contains($0.revision) }.count
        publishedArtifacts += publication.artifacts.count - failures
        return failures == 0 ? nil : "The arrangement was shared, but \(failures) snapshot\(failures == 1 ? "" : "s") could not be uploaded yet. Array retries when it reconnects or relaunches; until then teammates see no revision."
    }
    private func finishDelivery(_ result: SharedAreaController.Submission, wasUncertain: Bool) async {
        switch result {
        case .accepted:
            if let publication = pendingPublication, !publication.artifacts.isEmpty {
                message = "Shared. Uploading snapshots…"; onChange?()
                let failure = await publishArtifacts(publication)
                pendingPublication = nil; state = .published
                message = failure ?? "Shared. Each teammate views this arrangement and its snapshots without access to your files or checkout."
                onChange?(); onPublished?()
                return
            }
            pendingPublication = nil; state = .published
            message = "Shared. Each teammate views this arrangement without moving your source tiles or starting another agent."
            onChange?(); onPublished?()
        case .uncertain:
            state = .uncertain
            message = "Delivery is unknown. The exact request is saved in this workspace; check delivery now or reopen the workspace after relaunch."
            onChange?()
        case .rejected(let reason):
            // A retry of a previously uncertain request that cannot currently
            // reach authority still has an unknown outcome. Keep its identity.
            let resolvedRejection: Bool
            if let operation = pendingPublication?.command.id,
               let record = controller.deliveryRecord(for: operation), case .rejected = record.state {
                resolvedRejection = true
            } else { resolvedRejection = false }
            if wasUncertain && !resolvedRejection {
                state = .uncertain
                message = "Delivery is still unknown. Reconnect and check this same request again; current permission or revision errors do not undo an earlier commit."
            } else {
                state = .reviewing; pendingPublication = nil
                requiresRefresh = reason == .conflict || reason == .invalidCommand
                switch reason {
                case .conflict: message = "The shared workspace changed. Refresh the review before sharing."
                case .forbidden: message = "Your current permission does not allow publishing this selection."
                case .localPersistence: message = "The local source bindings could not be saved. Nothing was sent."
                default: message = "Sharing could not finish. Reconnect, refresh the review and try again."
                }
            }
            onChange?()
        }
    }

    private func makeReview(_ value: SharedAreaInventory.Snapshot) throws -> Publication.Review {
        guard value.inventory.workspaceID == workspaceID else { throw Failure.sourceWorkspaceChanged }
        guard let document = controller.document, document.id == review.manifest.area else { throw Failure.unavailableArea }
        return try Publication.prepare(inventory: value.inventory, selection: selection,
            choices: value.choices(for: modes, drafts: drafts), area: document.id, author: person, host: host,
            expectedRevision: document.revision)
    }

    static func message(for error: any Error) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .sourceWorkspaceChanged: return "The source workspace changed. Close this review and capture from the intended workspace again."
            case .unavailableArea: return "Open and reconnect the destination shared workspace before sharing."
            case .refreshRequired: return "Refresh the selection before changing or sharing this review."
            case .deliveryPending: return "Check delivery of the current request before changing this review."
            case .noSuchSource: return "This item is no longer part of the review."
            }
        }
        if let failure = error as? Publication.Failure {
            switch failure {
            case .reviewChanged: return "Source content or layout changed after review. Refresh and review the new selection before sharing."
            case .invalidContent: return "A selected note is empty or too large to share. Omit it or edit it before refreshing."
            case .publicationTooLarge: return "This capture is too large. Choose a smaller selection."
            case .invalidSelection, .missingSource: return "The selection is empty or an item is no longer available. Capture a new selection."
            default: return "The selection could not be reviewed. Refresh it before sharing."
            }
        }
        if let failure = error as? SharedAreaInventory.Failure { return failure.localizedDescription }
        return "The selection could not be read. Your source tiles and files are unchanged."
    }
}
