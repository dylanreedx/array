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
    private(set) var message = "Choose what to share for each note and managed agent. Unsupported tiles are excluded."
    private(set) var pendingPublication: Publication.Confirmed?
    var onChange: (() -> Void)?
    var onPublished: (() -> Void)?

    init(selection: Publication.Selection, controller: SharedAreaController,
         person: SharedArea.ID<SharedArea.Person>, host: SharedArea.ID<SharedArea.Host>,
         inventoryProvider: @escaping InventoryProvider, submitter: @escaping Submitter) throws {
        guard let document = controller.document else { throw Failure.unavailableArea }
        let initial = try inventoryProvider()
        self.selection = selection; self.controller = controller; self.person = person; self.host = host
        self.inventoryProvider = inventoryProvider; self.submitter = submitter
        snapshot = initial; workspaceID = initial.inventory.workspaceID
        review = try Publication.prepare(inventory: initial.inventory, selection: selection, choices: [],
            area: document.id, author: person, host: host, expectedRevision: document.revision)
    }

    var canEditReview: Bool { state == .reviewing && !requiresRefresh }
    var canConfirm: Bool { canEditReview && review.readyToConfirm && controller.canSubmit }
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
        do { review = try makeReview(snapshot) }
        catch { modes = previous; throw error }
        message = "Review the captured content and layout, then share. Source tiles and files stay on this Mac."
        onChange?()
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
        do {
            let fresh = try inventoryProvider()
            guard fresh.inventory.workspaceID == workspaceID else { throw Failure.sourceWorkspaceChanged }
            publication = try Publication.confirm(review, expectedDigest: review.digest,
                inventory: fresh.inventory, choices: fresh.choices(for: modes))
        } catch {
            requiresRefresh = true
            message = Self.message(for: error)
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
            finishDelivery(result, wasUncertain: true)
        } else {
            await deliver(pendingPublication)
        }
    }

    private func deliver(_ publication: Publication.Confirmed) async {
        let wasUncertain = state == .uncertain
        state = .submitting; message = "Sharing the reviewed selection…"; onChange?()
        let result = await submitter(publication)
        finishDelivery(result, wasUncertain: wasUncertain)
    }
    private func finishDelivery(_ result: SharedAreaController.Submission, wasUncertain: Bool) {
        switch result {
        case .accepted:
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
            choices: value.choices(for: modes), area: document.id, author: person, host: host,
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
