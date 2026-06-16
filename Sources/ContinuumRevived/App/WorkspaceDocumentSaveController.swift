import ContinuumRevivedCore
import Foundation

@MainActor
final class WorkspaceDocumentSaveController {
    private let store: WorkspaceStore
    private let defaults: UserDefaults
    private var timer: Timer?
    private var pendingDocument: WorkspaceDocument?

    init(store: WorkspaceStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    func scheduleZoneLayoutSave(_ document: WorkspaceDocument) {
        pendingDocument = document
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
        try store.save(document)
        pendingDocument = nil
    }
}
