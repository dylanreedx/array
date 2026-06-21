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
    private let store: WorkspaceStore
    private let defaults: UserDefaults
    private var timer: Timer?
    private var pendingDocument: WorkspaceDocument?
    private(set) var state: WorkspaceDocumentSaveState = .saved
    private(set) var lastError: Error?
    var onStateChange: ((WorkspaceDocumentSaveState) -> Void)?

    init(store: WorkspaceStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    func scheduleZoneLayoutSave(_ document: WorkspaceDocument) {
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
    }

    func flushPendingSave() throws {
        timer?.invalidate()
        timer = nil
        guard let document = pendingDocument else { return }
        setState(.saving)
        do {
            try store.save(document)
            pendingDocument = nil
            lastError = nil
            setState(.saved)
        } catch {
            lastError = error
            setState(.saveFailed)
            throw error
        }
    }

    private func setState(_ newState: WorkspaceDocumentSaveState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}
