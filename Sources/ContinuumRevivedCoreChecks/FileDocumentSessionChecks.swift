import ContinuumRevivedCore
import Foundation

private struct FileDocumentCheckError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func runFileDocumentSessionChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("array-file-document-session-\(UUID().uuidString)")
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let file = root.appendingPathComponent("main.swift")
    try! Data("let value = 1\n".utf8).write(to: file)
    let session = FileDocumentSession(path: file.path)
    expect(session.draftText == "let value = 1\n" && !session.isDirty,
           "file document session must load one UTF-8 disk baseline")

    let openingRevision = session.revision
    expect(session.updateDraft("let value = 2\n", expectedRevision: openingRevision) == .updated(revision: openingRevision + 1),
           "an editor mutation at the current revision must update the draft")
    expect(session.updateDraft("stale", expectedRevision: openingRevision) == .stale(currentRevision: openingRevision + 1)
            && session.draftText == "let value = 2\n",
           "a delayed editor mutation must not replace a newer draft")
    let recovery = session.recoverySnapshot(updatedAt: Date(timeIntervalSince1970: 7))
    expect(recovery?.baselineText == "let value = 1\n" && recovery?.draftText == "let value = 2\n",
           "recovery must retain both comparison baseline and complete draft")
    expect(session.save(expectedRevision: session.revision) == .saved(revision: session.revision),
           "an exact-revision save must atomically persist the draft")
    expect((try! String(contentsOf: file, encoding: .utf8)) == "let value = 2\n" && !session.isDirty,
           "a successful save must advance the baseline and clear dirty state")

    _ = session.updateDraft("local draft\n")
    try! Data("agent edit\n".utf8).write(to: file)
    expect(session.refreshFromDisk() == .conflict && session.draftText == "local draft\n",
           "external refresh must preserve a dirty local draft")
    expect(session.save() == .conflict && (try! String(contentsOf: file, encoding: .utf8)) == "agent edit\n",
           "ordinary save must fail closed when disk differs from the baseline")
    expect(session.save(overwriteExternalChanges: true) == .saved(revision: session.revision)
            && (try! String(contentsOf: file, encoding: .utf8)) == "local draft\n",
           "an explicit conflict overwrite must persist the retained draft")

    _ = session.updateDraft("do not recreate silently\n")
    try! fm.removeItem(at: file)
    expect(session.save() == .unavailable(.missing) && session.isDirty,
           "save must not recreate a file that disappeared after load")
    expect(!fm.fileExists(atPath: file.path), "missing-file save must leave disk untouched")

    let restored = FileDocumentSession(path: file.path)
    expect(recovery.map(restored.restoreRecovery) == true
            && restored.draftText == "let value = 2\n"
            && restored.externalState == .unavailable(.missing),
           "recovery must restore a missing file's draft while retaining unavailable state")

    try! Data("base\n".utf8).write(to: file)
    final class WriteFault: @unchecked Sendable { var attempts = 0 }
    let fault = WriteFault()
    let failingOperations = FileDocumentFileOperations(
        attributes: { try fm.attributesOfItem(atPath: $0) },
        read: { try Data(contentsOf: $0) },
        write: { _, _ in
            fault.attempts += 1
            throw FileDocumentCheckError(message: String(repeating: "write failed ", count: 40))
        }
    )
    let failing = FileDocumentSession(path: file.path, fileOperations: failingOperations)
    _ = failing.updateDraft("valuable draft\n")
    let failure = failing.save()
    guard case let .writeFailed(message) = failure else {
        expect(false, "writer failure must produce a typed save failure")
        return
    }
    expect(fault.attempts == 1 && failing.isDirty && failing.baselineText == "base\n",
           "writer failure must retain the draft and old baseline")
    expect(message.count <= 240, "persisted/UI-facing writer diagnostics must be bounded")

    let reconciled = FileDocumentSession(path: file.path)
    expect(reconciled.synchronizeDraft("snapshot\n", revision: 7) == .updated(revision: 7),
           "a full web snapshot must restore its monotonic editor revision")
    expect(reconciled.synchronizeDraft("stale\n", revision: 6) == .stale(currentRevision: 7)
           && reconciled.draftText == "snapshot\n",
           "a stale full snapshot must not replace the newer native draft")

    let oversized = String(repeating: "x", count: FileDocumentSession.maxBytes + 1)
    _ = failing.updateDraft(oversized)
    expect(failing.save() == .draftTooLarge(maxBytes: FileDocumentSession.maxBytes) && fault.attempts == 1,
           "oversized drafts must fail before attempting a write")

    let state = FileEditorViewState(
        sidebarExpanded: false, sidebarWidth: 284, expandedPaths: ["Sources", "Sources/App"],
        selectedPath: "Sources/App/main.swift", searchQuery: "session", cursorLine: 18,
        cursorColumn: 7, verticalScrollOffset: 321, horizontalScrollOffset: 14
    )
    let metadata = TileMetadata(filePath: file.path, fileEditorViewState: state)
    let roundTrip = try! JSONDecoder().decode(TileMetadata.self, from: JSONEncoder().encode(metadata))
    expect(roundTrip.fileEditorViewState == state, "file editor presentation state must round-trip with tile metadata")
    let legacy = try! JSONDecoder().decode(TileMetadata.self, from: Data("{\"filePath\":\"legacy.swift\"}".utf8))
    expect(legacy.fileEditorViewState == nil, "legacy tile metadata must decode without editor presentation state")
}
