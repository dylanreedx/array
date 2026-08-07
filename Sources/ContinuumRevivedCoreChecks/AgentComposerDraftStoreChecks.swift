import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

private final class DraftWarningBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func draftImageMetadata(_ index: Int) -> AgentImageAttachmentMetadata {
    AgentImageAttachmentMetadata(
        id: AgentImageAttachmentID(rawValue: "draft-local-image-\(index)")!,
        displayName: "draft-image-\(index).png",
        contentType: "image/png",
        byteCount: UInt64(index + 100),
        pixelWidth: UInt(index + 10),
        pixelHeight: UInt(index + 20)
    )
}

private func draftImageAttachment(_ index: Int) -> AgentComposerDraftImageAttachment {
    AgentComposerDraftImageAttachment(metadata: draftImageMetadata(index))
}

/// Deliberately asserts the regressed ordering. The parent check launches this
/// in a subprocess and requires the production assertion to fail, preserving an
/// actual deterministic red witness rather than a comment claiming one occurred.
func runAgentComposerDraftStoreOrderingNegativeWitness() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentComposerDraftStoreNegativeWitness-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let agent = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009449")!)
    let store = AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 60)
    let older = AgentComposerDraft(text: "older", selection: 0..<5, updatedAt: Date(timeIntervalSince1970: 10))
    let newer = AgentComposerDraft(text: "newer", selection: 0..<5, updatedAt: Date(timeIntervalSince1970: 20))
    await store.save(newer, for: agent)
    await store.save(older, for: agent)
    let restored = await store.load(for: agent)
    expect(restored == older, "negative witness: out-of-order save regressed the newest draft")
}

// Ticket 91/P4.4 + IMAGE WAVE 2A Lane A: sensitive unfinished prompts and
// opaque local image attachment references are local, per-agent, debounced, and
// cleared only at the accepted-send boundary after sent ownership is retained.
func runAgentComposerDraftStoreChecks() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentComposerDraftStoreChecks-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let agentA = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009441")!)
    let agentB = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009442")!)
    let base = Date(timeIntervalSince1970: 1_800_094_400)
    let draftA = AgentComposerDraft(
        text: "alpha 👩🏽‍💻 draft",
        selection: 6..<13,
        updatedAt: base,
        imageAttachments: [draftImageAttachment(1), draftImageAttachment(2)]
    )
    let draftB = AgentComposerDraft(text: "beta\nsecond line", selection: 2..<9, updatedAt: base.addingTimeInterval(1))
    let warnings = DraftWarningBox()
    let store = AgentComposerDraftStore(
        applicationSupportDirectory: root,
        debounceInterval: 60,
        warn: { warnings.append($0) }
    )

    let legacyDraftJSON = """
    {"text":"legacy","selection":[0,6],"updatedAt":"2026-08-07T02:40:11Z"}
    """.data(using: .utf8)!
    let legacyDecoded = try JSONCodec.makeDecoder().decode(AgentComposerDraft.self, from: legacyDraftJSON)
    expect(legacyDecoded.imageAttachments.isEmpty,
           "legacy persisted composer drafts without imageAttachments must decode with an empty attachment list")

    await store.save(draftA, for: agentA)
    await store.save(draftB, for: agentB)
    let layout = await store.layout

    // Bounded/debounced: save updates memory but does not AtomicWriter/fsync once
    // per keystroke. Negative witness observed red by replacing `save`'s scheduled
    // flush with an immediate `flush(agentID:)` call.
    expect(!FileManager.default.fileExists(atPath: layout.draftFile(for: agentA).path),
           "draft save must be debounced rather than writing per keystroke")
    let pendingA = await store.load(for: agentA)
    expect(pendingA == draftA,
           "an outstanding debounce must still expose the newest in-memory draft including attachments")

    let newestA = AgentComposerDraft(
        text: "newest alpha",
        selection: 2..<7,
        updatedAt: base.addingTimeInterval(10),
        imageAttachments: [draftImageAttachment(3)]
    )
    let olderA = AgentComposerDraft(
        text: "late older alpha", selection: 0..<4, updatedAt: base.addingTimeInterval(5)
    )
    await store.save(newestA, for: agentA)
    await store.save(olderA, for: agentA)
    let pendingNewestA = await store.load(for: agentA)
    expect(pendingNewestA == newestA,
           "an older independently enqueued save must not regress the newest agent draft")

    await store.flushAll()
    expect(FileManager.default.fileExists(atPath: layout.draftFile(for: agentA).path),
           "flush must persist the first agent draft")
    expect(FileManager.default.fileExists(atPath: layout.draftFile(for: agentB).path),
           "flush must persist the second agent draft")

    // A new actor simulates tile detach/re-attach and app relaunch.
    let relaunched = AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 60)
    let restoredA = await relaunched.load(for: agentA)
    let restoredB = await relaunched.load(for: agentB)
    expect(restoredA == newestA,
           "agent A must restore its exact newest text, UTF-16 selection, timestamp, and image attachment refs")
    expect(restoredA?.imageAttachments.map(\.attachmentID) == newestA.imageAttachments.map(\.attachmentID),
           "relaunch persistence must retain opaque attachment ids in order")
    expect(restoredB == draftB,
           "agent B must restore its distinct exact draft")
    expect(restoredA != restoredB,
           "two agents must never alias one shared draft")

    // Rejection preserves both memory and disk. Negative witness observed red by
    // removing the accepted guard in resolveSendIntent: this assertion failed.
    await relaunched.resolveSendIntent(for: agentA, accepted: false)
    let afterRejection = await relaunched.load(for: agentA)
    expect(afterRejection == newestA,
           "a rejected send intent must keep the draft")
    await relaunched.resolveSendIntent(for: agentA, accepted: true)
    let afterAcceptance = await relaunched.load(for: agentA)
    let unaffectedB = await relaunched.load(for: agentB)
    expect(afterAcceptance == nil,
           "an accepted send intent must clear that agent's draft")
    let staleQueuedSave = AgentComposerDraft(
        text: "stale task", selection: 0..<4, updatedAt: Date(timeIntervalSince1970: 1)
    )
    await relaunched.save(staleQueuedSave, for: agentA)
    let afterStaleSave = await relaunched.load(for: agentA)
    expect(afterStaleSave == nil,
           "a pre-acceptance save task arriving late must not resurrect the cleared draft")
    expect(unaffectedB == draftB,
           "clearing agent A must not clear agent B")

    let draftDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: layout.draftsDirectory.path)
    let draftFileAttributes = try FileManager.default.attributesOfItem(atPath: layout.draftFile(for: agentB).path)
    expect((draftDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
           "sensitive draft directory permissions must be 0700")
    expect((draftFileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
           "sensitive draft file permissions must be 0600")
    expect(!FileManager.default.fileExists(atPath: layout.backupsDirectory.path),
           "draft persistence must never create pre-prune backups containing prompt text")
    expect(layout.draftsDirectory.deletingLastPathComponent() == root,
           "drafts must remain in local Application Support")
    expect(!layout.draftsDirectory.path.contains("/agents/"),
           "prompt drafts must not be fields/files in the AgentRecord store")

    try await runAgentComposerAttachmentStoreChecks(root: root, agentA: agentA, agentB: agentB, warnings: warnings)

    // Corrupt only the draft file. Loading fails safely and the independent
    // AgentRecord-like sentinel proves this path cannot delete agent records.
    let sentinel = root.appendingPathComponent("agents/sentinel.json")
    try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("agent-record-sentinel".utf8).write(to: sentinel)
    try Data("{ definitely-not-json".utf8).write(to: layout.draftFile(for: agentB))
    let corruptStore = AgentComposerDraftStore(
        applicationSupportDirectory: root,
        warn: { warnings.append($0) }
    )
    let corruptDraft = await corruptStore.load(for: agentB)
    expect(corruptDraft == nil,
           "a corrupt draft must fail safely to no restored draft")
    expect(FileManager.default.fileExists(atPath: sentinel.path),
           "a corrupt draft must never delete agent records")
    let warningSnapshot = warnings.snapshot()
    expect(warningSnapshot.contains { $0.contains("unreadable draft") },
           "corrupt draft failure should identify the local draft path without logging its body")
    expect(!warningSnapshot.joined(separator: " ").contains(draftB.text),
           "draft diagnostics must never include prompt bodies")

    let witness = Process()
    witness.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    witness.arguments = ["--agent-composer-draft-store-ordering-negative-witness"]
    let witnessError = Pipe()
    witness.standardError = witnessError
    try witness.run()
    witness.waitUntilExit()
    let witnessOutput = String(
        data: witnessError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
    ) ?? ""
    expect(witness.terminationStatus != 0,
           "the out-of-order regression negative witness must be observed red")
    let expectedWitness = "FAIL: negative witness: out-of-order save regressed the newest draft"
    expect(witnessOutput.contains(expectedWitness),
           "the negative witness must fail at the named production ordering assertion")
    print("AgentComposerDraftStore negative witness observed red (exit \(witness.terminationStatus)): \(expectedWitness)")

    print("AgentComposerDraftStore checks passed: backward draft decoding, exact per-agent attachment restores, out-of-order rejection with subprocess red witness, debounced AtomicWriter persistence, explicit submission recovery/confirmed-start lifecycle, all-or-nothing attachment batch preparation, caller-validated image imports, symlink/cross-agent/manifest/missing-item rejection, manifest-write rollback, honest cleanup failure reporting, no prompt backups, private permissions, and safe corruption isolation")
}

private func runAgentComposerAttachmentStoreChecks(
    root: URL,
    agentA: AgentID,
    agentB: AgentID,
    warnings: DraftWarningBox
) async throws {
    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_800_094_500))
    let attachmentStore = AgentComposerAttachmentStore(
        applicationSupportDirectory: root,
        clock: clock,
        warn: { warnings.append($0) }
    )
    let attachmentLayout = await attachmentStore.layout
    let pngValidation = try AgentComposerImageValidation(
        validatedContentType: "image/png",
        pixelWidth: 2,
        pixelHeight: 2
    )
    let jpegValidation = try AgentComposerImageValidation(validatedContentType: "image/jpeg")

    do {
        _ = try AgentComposerImageValidation(validatedContentType: "text/plain")
        expect(false, "Core import must require caller image validation before storage")
    } catch AgentComposerAttachmentStoreError.imageInputNotValidated {
        // Expected: Core is platform-neutral but the import caller must prove image-ness.
    }

    let pasted = try await attachmentStore.importValidatedPastedImage(
        Data([0x89, 0x50, 0x4E, 0x47]),
        displayName: "../pasted.png",
        validation: pngValidation,
        forDraftOf: agentA
    )
    expect(pasted.manifest.metadata.displayName == "pasted.png",
           "managed imports must store display metadata without source path traversal components")
    let pastedURL = try await attachmentStore.fileURL(for: pasted.manifest.id)
    expect(pastedURL == pasted.fileURL && FileManager.default.fileExists(atPath: pasted.fileURL.path),
           "opaque attachment ids must resolve to imported local files")
    let attachmentRootPrefix = attachmentLayout.attachmentsDirectory.standardizedFileURL.path + "/"
    expect(pasted.fileURL.standardizedFileURL.path.hasPrefix(attachmentRootPrefix),
           "resolved files must remain under the managed Application Support attachment root")
    expect(!pasted.manifest.relativePath.hasPrefix("/") && !pasted.manifest.relativePath.contains(".."),
           "manifest storage paths must be relative and traversal-safe")
    let pastedFileAttributes = try FileManager.default.attributesOfItem(atPath: pasted.fileURL.path)
    expect((pastedFileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
           "imported attachment files must be restricted to 0600")

    let source = root.appendingPathComponent("incoming/local-source.jpg")
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0xFF, 0xD8, 0xFF]).write(to: source)
    let localFile = try await attachmentStore.importValidatedLocalImageFile(source, validation: jpegValidation, forDraftOf: agentA)
    expect(localFile.manifest.metadata.displayName == "local-source.jpg" && localFile.manifest.metadata.contentType == "image/jpeg",
           "local file import must copy bytes while retaining only path-free filename/type metadata")
    expect(localFile.fileURL != source && FileManager.default.fileExists(atPath: localFile.fileURL.path),
           "local file import must copy into managed storage rather than retaining the original absolute path")

    let prepared = try await attachmentStore.preparePromptAttachments(
        for: agentA,
        draftAttachments: [pasted.draftAttachment, localFile.draftAttachment]
    )
    expect(prepared.map(\.metadata.id) == [pasted.manifest.id, localFile.manifest.id],
           "batch preparation must preserve complete draft attachment count and order")
    do {
        _ = try await attachmentStore.preparePromptAttachments(for: agentB, draftAttachments: [pasted.draftAttachment])
        expect(false, "cross-agent batch preparation must not resolve another agent's attachment")
    } catch AgentComposerAttachmentStoreError.ownershipMismatch(let id, let expected, let actual) {
        expect(id == pasted.manifest.id && expected == agentB && actual == agentA,
               "cross-agent ownership mismatch must identify expected/actual ownership without preparing a partial batch")
    }
    do {
        var tamperedDraft = pasted.draftAttachment
        tamperedDraft.metadata.displayName = "tampered.png"
        _ = try await attachmentStore.preparePromptAttachments(for: agentA, draftAttachments: [tamperedDraft])
        expect(false, "draft/manifest metadata mismatch must fail all-or-nothing preparation")
    } catch AgentComposerAttachmentStoreError.draftMetadataMismatch(let id) {
        expect(id == pasted.manifest.id, "metadata mismatch should identify the tampered attachment id")
    }
    let missingDraft = AgentComposerDraftImageAttachment(
        metadata: AgentImageAttachmentMetadata(
            id: AgentImageAttachmentID(rawValue: "draft-missing-batch-item")!,
            displayName: "missing.png",
            contentType: "image/png"
        )
    )
    do {
        _ = try await attachmentStore.preparePromptAttachments(for: agentA, draftAttachments: [pasted.draftAttachment, missingDraft])
        expect(false, "a missing item must fail batch preparation without returning a partial send")
    } catch AgentComposerAttachmentStoreError.missingAttachment(let id) {
        expect(id == missingDraft.attachmentID, "missing batch item should identify the absent attachment")
    }

    let badID = AgentImageAttachmentID(rawValue: "draft-bad-relative-path")!
    let badManifest = AgentComposerAttachmentManifest(
        id: badID,
        metadata: AgentImageAttachmentMetadata(id: badID, displayName: "bad.png"),
        relativePath: "../outside.png",
        ownership: .draft(agentID: agentA, at: clock.now()),
        createdAt: clock.now(),
        updatedAt: clock.now()
    )
    try FileManager.default.createDirectory(at: attachmentLayout.manifestsDirectory, withIntermediateDirectories: true)
    try JSONCodec.makeEncoder(prettyPrinted: true).encode(badManifest).write(to: attachmentLayout.manifestFile(for: badID))
    do {
        _ = try await attachmentStore.fileURL(for: badID)
        expect(false, "tampered relative paths must not resolve outside the attachment root")
    } catch AgentComposerAttachmentStoreError.unsafeRelativePath {
        // Expected path safety oracle.
    }

    let mismatchKeyID = AgentImageAttachmentID(rawValue: "draft-manifest-key-mismatch-key")!
    let mismatchActualID = AgentImageAttachmentID(rawValue: "draft-manifest-key-mismatch-actual")!
    let mismatchManifest = AgentComposerAttachmentManifest(
        id: mismatchActualID,
        metadata: AgentImageAttachmentMetadata(id: mismatchActualID, displayName: "mismatch.png"),
        relativePath: pasted.manifest.relativePath,
        ownership: .draft(agentID: agentA, at: clock.now()),
        createdAt: clock.now(),
        updatedAt: clock.now()
    )
    try JSONCodec.makeEncoder(prettyPrinted: true).encode(mismatchManifest).write(to: attachmentLayout.manifestFile(for: mismatchKeyID))
    do {
        _ = try await attachmentStore.preparePromptAttachments(
            for: agentA,
            draftAttachments: [AgentComposerDraftImageAttachment(metadata: AgentImageAttachmentMetadata(id: mismatchKeyID, displayName: "mismatch.png"))]
        )
        expect(false, "manifest key/id mismatch must fail before prompt preparation")
    } catch AgentComposerAttachmentStoreError.manifestIdentityMismatch(let expected, let actual) {
        expect(expected == mismatchKeyID && actual == mismatchActualID,
               "manifest identity mismatch should bind the storage key to decoded id")
    }
    try? FileManager.default.removeItem(at: attachmentLayout.manifestFile(for: mismatchKeyID))

    let symlinkID = AgentImageAttachmentID(rawValue: "draft-symlink-escape")!
    let outside = root.appendingPathComponent("outside-symlink-target.png")
    try Data([9, 9, 9]).write(to: outside)
    let symlinkURL = attachmentLayout.objectsDirectory.appendingPathComponent("escape-link.bin")
    try? FileManager.default.removeItem(at: symlinkURL)
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outside)
    let symlinkManifest = AgentComposerAttachmentManifest(
        id: symlinkID,
        metadata: AgentImageAttachmentMetadata(id: symlinkID, displayName: "escape.png", contentType: "image/png"),
        relativePath: "objects/escape-link.bin",
        ownership: .draft(agentID: agentA, at: clock.now()),
        createdAt: clock.now(),
        updatedAt: clock.now()
    )
    try JSONCodec.makeEncoder(prettyPrinted: true).encode(symlinkManifest).write(to: attachmentLayout.manifestFile(for: symlinkID))
    do {
        _ = try await attachmentStore.preparePromptAttachments(for: agentA, draftAttachments: [symlinkManifest.draftAttachment])
        expect(false, "symlink escape under the managed root must be rejected before transport")
    } catch AgentComposerAttachmentStoreError.unsafeRelativePath {
        // Expected canonical containment oracle.
    }

    var manyDraftAttachments: [AgentComposerDraftImageAttachment] = []
    for index in 0..<64 {
        let imported = try await attachmentStore.importValidatedPastedImage(
            Data(repeating: UInt8(index), count: index + 1),
            displayName: "many-\(index).png",
            validation: pngValidation,
            forDraftOf: agentB
        )
        manyDraftAttachments.append(imported.draftAttachment)
    }
    let manyDraft = AgentComposerDraft(
        text: "many attachments",
        selection: 0..<16,
        updatedAt: clock.now(),
        imageAttachments: manyDraftAttachments
    )
    let manyStore = AgentComposerDraftStore(
        applicationSupportDirectory: root,
        debounceInterval: 60,
        attachmentStore: attachmentStore,
        clock: clock
    )
    await manyStore.save(manyDraft, for: agentB)
    await manyStore.flushAll()
    let manyRelaunched = AgentComposerDraftStore(applicationSupportDirectory: root, attachmentStore: attachmentStore, clock: clock)
    let restoredMany = await manyRelaunched.load(for: agentB)
    expect(restoredMany?.imageAttachments.count == 64,
           "composer drafts must persist many image attachments without an arbitrary count cap")

    let lifecycleDraft = AgentComposerDraft(
        text: "send with image",
        selection: 0..<15,
        updatedAt: clock.now(),
        imageAttachments: [pasted.draftAttachment, localFile.draftAttachment]
    )
    let lifecycleStore = AgentComposerDraftStore(
        applicationSupportDirectory: root,
        debounceInterval: 60,
        attachmentStore: attachmentStore,
        clock: clock
    )
    await lifecycleStore.save(lifecycleDraft, for: agentA)
    await lifecycleStore.flushAll()
    await lifecycleStore.resolveSendIntent(for: agentA, accepted: false)
    let rejectedDraft = await lifecycleStore.load(for: agentA)
    let rejectedManifest = try await attachmentStore.manifest(for: pasted.manifest.id)
    expect(rejectedDraft == lifecycleDraft && rejectedManifest?.ownership.state == .draft,
           "rejected sends must preserve both the draft attachment refs and draft-owned files")

    let beganPreStart = try await lifecycleStore.beginSubmission(for: agentA, submittedAt: clock.now())
    let hiddenPreStart = await lifecycleStore.load(for: agentA)
    expect(beganPreStart && hiddenPreStart == nil,
           "beginSubmission must clear visible state only after retaining a durable recovery snapshot")
    let restoredPreStart = try await lifecycleStore.restoreSubmission(for: agentA)
    let visibleAfterRestore = await lifecycleStore.load(for: agentA)
    expect(restoredPreStart == lifecycleDraft && visibleAfterRestore == lifecycleDraft,
           "pre-start rejection must restore the exact draft and attachment refs from recovery")

    let beganConfirmed = try await lifecycleStore.beginSubmission(for: agentA, submittedAt: clock.now())
    let hiddenBeforeConfirm = await lifecycleStore.load(for: agentA)
    expect(beganConfirmed && hiddenBeforeConfirm == nil,
           "confirmed-start path must start from a hidden visible draft plus durable recovery")
    let confirmed = try await lifecycleStore.confirmSubmissionStarted(for: agentA, sentAt: clock.now())
    let acceptedDraft = await lifecycleStore.load(for: agentA)
    let sentPasted = try await attachmentStore.storedAttachment(for: pasted.manifest.id)
    let sentLocal = try await attachmentStore.storedAttachment(for: localFile.manifest.id)
    expect(confirmed && acceptedDraft == nil,
           "confirmed provider start must clear durable recovery without restoring visible draft")
    expect(sentPasted?.manifest.ownership.state == .sent && sentLocal?.manifest.ownership.state == .sent,
           "confirmed provider start must transfer attachment ownership to sent instead of deleting originals")
    expect(FileManager.default.fileExists(atPath: sentPasted!.fileURL.path) && FileManager.default.fileExists(atPath: sentLocal!.fileURL.path),
           "confirmed-start transfer must not prematurely delete files that transcript metadata may reference")

    let manifestFaultRoot = root.appendingPathComponent("manifest-fault", isDirectory: true)
    let manifestFaultStore = AgentComposerAttachmentStore(
        applicationSupportDirectory: manifestFaultRoot,
        clock: clock,
        manifestWriter: { _, _ in throw CocoaError(.fileWriteUnknown) }
    )
    do {
        _ = try await manifestFaultStore.importValidatedPastedImage(
            Data([7, 7, 7]),
            displayName: "fault.png",
            validation: pngValidation,
            forDraftOf: agentA
        )
        expect(false, "manifest persistence failure must fail the import")
    } catch {
        let faultObjects = manifestFaultRoot
            .appendingPathComponent("agent-composer-attachments/objects", isDirectory: true)
        let remainingObjects = (try? FileManager.default.contentsOfDirectory(at: faultObjects, includingPropertiesForKeys: nil)) ?? []
        expect(remainingObjects.isEmpty,
               "object bytes written before a manifest fault must be rolled back")
    }

    let cleanupFaultRoot = root.appendingPathComponent("cleanup-fault", isDirectory: true)
    let cleanupFaultStore = AgentComposerAttachmentStore(
        applicationSupportDirectory: cleanupFaultRoot,
        clock: clock,
        removeItem: { _ in throw CocoaError(.fileWriteNoPermission) }
    )
    let cleanupFaultItem = try await cleanupFaultStore.importValidatedPastedImage(
        Data([8, 8, 8]),
        displayName: "cleanup-fault.png",
        validation: pngValidation,
        forDraftOf: agentA
    )
    clock.advance(by: 7_200)
    do {
        _ = try await cleanupFaultStore.cleanupUnreferencedDraftAttachments(retaining: [], graceInterval: 3_600)
        expect(false, "cleanup deletion failures must be reported instead of counted as removed")
    } catch AgentComposerAttachmentStoreError.cleanupDeletionFailed(let failures) {
        expect(failures.contains { $0.contains(cleanupFaultItem.manifest.id.rawValue) },
               "cleanup failure report should name the attachment id that could not be deleted")
    }

    let orphan = try await attachmentStore.importValidatedPastedImage(
        Data([1, 2, 3]),
        displayName: "orphan.png",
        validation: pngValidation,
        forDraftOf: agentA
    )
    let retainedID = manyDraftAttachments[0].attachmentID
    let immediateCleanup = try await attachmentStore.cleanupUnreferencedDraftAttachments(retaining: [retainedID], graceInterval: 3_600)
    expect(!immediateCleanup.contains(orphan.manifest.id),
           "cleanup must honor the injected-clock grace seam and not delete fresh draft files")
    clock.advance(by: 7_200)
    let cleanup = try await attachmentStore.cleanupUnreferencedDraftAttachments(retaining: [retainedID], graceInterval: 3_600)
    expect(cleanup.contains(orphan.manifest.id),
           "stale unreferenced draft-owned files may be cleaned only after the grace seam")
    let retainedURLAfterCleanup = try await attachmentStore.fileURL(for: retainedID)
    expect(retainedURLAfterCleanup != nil,
           "cleanup must retain explicitly referenced draft attachments")
    let sentURLAfterCleanup = try await attachmentStore.fileURL(for: pasted.manifest.id)
    expect(sentURLAfterCleanup != nil,
           "cleanup must never remove sent attachments referenced by transcript metadata")
}
