import ContinuumRevivedCore
import Foundation

@MainActor
enum WorkspaceDocumentSaveState: String, Equatable {
    case saved
    case saving
    case unsavedChanges
    case saveFailed

    var displayTitle: String {
        switch self {
        case .saved: return "Saved"
        case .saving: return "Saving…"
        case .unsavedChanges: return "Unsaved changes"
        case .saveFailed: return "Save failed"
        }
    }
}

@MainActor
final class WorkspaceDocumentSaveController {
    private let store: any WorkspaceStoring
    private let defaults: UserDefaults
    private var timer: Timer?
    private var pendingDocument: WorkspaceDocument?
    private(set) var state: WorkspaceDocumentSaveState = .saved
    private(set) var lastError: Error?
    private(set) var scheduledGeneration: UInt64 = 0
    private(set) var acknowledgedGeneration: UInt64 = 0
    var onStateChange: ((WorkspaceDocumentSaveState) -> Void)?

    init(store: any WorkspaceStoring, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    @discardableResult
    func scheduleZoneLayoutSave(_ document: WorkspaceDocument) -> UInt64 {
        scheduledGeneration &+= 1
        pendingDocument = document
        lastError = nil
        setState(.unsavedChanges)
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: AutosaveConfig.debounceInterval(defaults: defaults),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in try? self?.flushPendingSave() }
        }
        return scheduledGeneration
    }

    func flushPendingSave() throws {
        timer?.invalidate()
        timer = nil
        guard let document = pendingDocument else { return }
        setState(.saving)
        do {
            try store.save(document)
            pendingDocument = nil
            acknowledgedGeneration = scheduledGeneration
            lastError = nil
            setState(.saved)
        } catch {
            lastError = error
            setState(.saveFailed)
            throw error
        }
    }

    func flush(through generation: UInt64) throws {
        if acknowledgedGeneration >= generation { return }
        try flushPendingSave()
        guard acknowledgedGeneration >= generation else {
            throw WorkspaceSaveAcknowledgementError.generationNotAcknowledged(
                requested: generation, acknowledged: acknowledgedGeneration)
        }
    }

    private func setState(_ newState: WorkspaceDocumentSaveState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}

enum WorkspaceSaveAcknowledgementError: Error, Equatable {
    case generationNotAcknowledged(requested: UInt64, acknowledged: UInt64)
}
