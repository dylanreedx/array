#if ARRAY_CHECKS
import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// A lead's turn shows the files its helper made.
///
/// In Managed mode the helper makes the file and the lead only reads it, so the
/// lead's tile — the one Dylan watches — never had a Changes card
/// (2026-11-25: helper 498B04C8 wrote ufc-schedule.md, lead 4CE901B5 read it,
/// and nothing showed where he was looking).
///
/// Drives the real supervisor: a helper whose provider stream goes through the
/// real claude translator `Write`s a report (twice, as agents redo a file) and
/// makes a PNG through the shell, files its report and ends; its result wakes
/// the real lead. The lead's turn must draw one Changes card with both files,
/// each carrying the helper's identity, and the helper's own tile must show its
/// own files. Then the lead is restored from a session file, as a relaunch
/// does, and must draw the same card.
@MainActor
enum LeadHelperFilesChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    /// A claude helper: each turn is its stream-json lines through the real
    /// translator, with the files made on disk between a call and its result.
    final class ScriptedClaudeRunner: AgentRunning, @unchecked Sendable {
        struct Step { let line: [String: Any]; let before: (() -> Void)? }
        private let lock = NSLock()
        private var observer: (@Sendable (AgentRuntimeObservation) -> Void)?
        private let root: URL
        private let steps: [Step]
        let toolsDone = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        init(root: URL, steps: [Step]) { self.root = root; self.steps = steps }
        var commandCapabilities: AgentSessionCommandCapabilities { .oneShotProse }

        func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
            let turnID = UUID().uuidString
            onEvent(.turnStarted(threadId: "", turnId: turnID))
            // A provider's first tool call comes well after its turn starts; the
            // tile adopts the turn before any tool's facts arrive.
            Thread.sleep(forTimeInterval: 0.3)
            var translator = ClaudeEventTranslator(workingDirectory: root)
            let observe = lock.withLock { observer }
            translator.onRuntimeObservation = { observe?($0) }
            for step in steps {
                step.before?()
                let line = String(data: try JSONSerialization.data(withJSONObject: step.line), encoding: .utf8)!
                translator.translate(line: line).forEach(onEvent)
            }
            toolsDone.signal()
            release.wait()
            onEvent(.turnCompleted(threadId: "", turnId: turnID, outcome: .completed, errorMessage: nil))
        }
        func waitForTools() -> Bool { toolsDone.wait(timeout: .now() + 10) == .success }
        func stop() { release.signal() }
        func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
        func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {
            lock.withLock { observer = handler }
        }
    }

    static func run(stillsDirectory: URL? = nil) async throws {
        let fileManager = FileManager.default
        // Not the temp folder: the shell rule skips it as scratch.
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = caches.appendingPathComponent("array-lead-helper-files-qa/\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try fileManager.createDirectory(at: work.appendingPathComponent("captures"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        // The supervisor's own logs go to a support folder this check owns.
        let previousSupport = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"]
        setenv("CONTINUUM_APP_SUPPORT", root.appendingPathComponent("support").path, 1)
        defer {
            if let previousSupport { setenv("CONTINUUM_APP_SUPPORT", previousSupport, 1) } else { unsetenv("CONTINUUM_APP_SUPPORT") }
        }

        let model = AgentCatalogQAFixture.pi[0]
        let previousCatalog = AgentModelCatalog.shared.snapshot(for: .pi)
        defer { AgentModelCatalog.shared.resetForQA(snapshot: previousCatalog) }
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready,
            models: [model], displayNames: [:], refreshedAt: Date()))
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let lead = AgentID(rawValue: UUID()), helper = AgentID(rawValue: UUID())
        var leadRecord = AgentRecord(id: lead, displayName: "Release lead", harness: .pi, model: model, thinking: "medium",
            cwd: work.path, createdAt: Date(), lastActivityAt: Date())
        leadRecord.workspaceToolsEnabled = true
        try store.upsert(leadRecord)
        var helperRecord = AgentRecord(id: helper, displayName: "December UFC schedule", harness: .pi, model: model,
            thinking: "medium", cwd: work.path, parentAgentID: lead, createdAt: Date(), lastActivityAt: Date())
        helperRecord.identityColor = "teal"
        helperRecord.spawnResultHandle = "helper-files"
        SpawnResultFile.write(.init(toolCallId: "helper-files", status: .spawned, agentId: helper.rawValue,
            recipientId: lead.rawValue), parentCwd: work.path, warn: { _ in })
        try store.upsert(helperRecord)

        // The helper's turn, as claude streams it.
        let report = work.appendingPathComponent("ufc-schedule.md")
        let shot = work.appendingPathComponent("captures/fight-card.png")
        let first = "# UFC schedule\n\nResearched Nov 25, 2026\n\n- Dec 5: Riyadh\n"
        let second = first + "- Dec 12: UFC 335\n"
        func use(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
            ["type": "assistant", "message": ["id": "msg-\(id)", "role": "assistant", "content": [
                ["type": "tool_use", "id": id, "name": name, "input": input]]]]
        }
        func result(_ id: String, _ text: String) -> [String: Any] {
            ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text]]]]
        }
        let screencapture = "screencapture -x \(shot.path)"
        let helperRunner = ScriptedClaudeRunner(root: work, steps: [
            .init(line: use("toolu_write_1", "Write", ["file_path": report.path, "content": first]), before: nil),
            .init(line: result("toolu_write_1", "File created successfully at: \(report.path)"),
                  before: { try? Data(first.utf8).write(to: report) }),
            .init(line: use("toolu_write_2", "Write", ["file_path": report.path, "content": second]), before: nil),
            .init(line: result("toolu_write_2", "The file \(report.path) has been updated successfully."),
                  before: { try? Data(second.utf8).write(to: report) }),
            .init(line: use("toolu_shot", "Bash", ["command": screencapture, "description": "Capture the fight card"]), before: nil),
            .init(line: result("toolu_shot", ""), before: { try? ShellMadeFilesChecks.picture(NSColor.systemTeal).write(to: shot) }),
        ])
        // The lead's wake turn stays open while it reads the file, as a real one does.
        let leadRunner = HelperCompletionChecks.HeldWakeRunner(autoEnd: false)
        let runners: [AgentID: AgentRunning] = [lead: leadRunner, helper: helperRunner]
        let s = AgentSupervisor(store: store, makeRunner: { runners[$0.record.id]! }, warn: { _ in },
            nameTitlerCommand: { _ in nil },
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root.appendingPathComponent("drafts")),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)),
            maximumActiveManagedChildren: { nil })
        _ = s.restore()
        defer { s.stopAll() }
        var now = Date()
        s.helperCompletionNow = { now }

        func tile(_ id: AgentID, dark: Bool) -> (ManagedAgentTileNSView, NSWindow) {
            let view = ManagedAgentTileNSView(tile: Tile(
                id: UUID(), kind: .managedAgent, title: "agent", frame: TileFrame(x: 0, y: 0, width: 640, height: 620),
                zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
            view.frame = NSRect(x: 0, y: 0, width: 640, height: 620)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = view
            window.orderFrontOffscreenForChecks()
            return (view, window)
        }
        let (leadTile, leadWindow) = tile(lead, dark: false)
        let (helperTile, helperWindow) = tile(helper, dark: false)
        defer { leadWindow.orderOut(nil); helperWindow.orderOut(nil) }
        leadTile.attach(agentID: lead, supervisor: s)
        helperTile.attach(agentID: helper, supervisor: s)

        // The helper works, reports and ends; its result wakes the lead.
        try expect(s.send("Research the December UFC schedule into ufc-schedule.md.", to: helper), "the helper did not take its task")
        let toolsDone = await Task.detached { helperRunner.waitForTools() }.value
        try expect(toolsDone, "the helper's tool calls did not run")
        _ = await waitUntil(timeout: 2, pollInterval: 0.05) { false }
        try expect(s.fileReport(.init(summary: "Wrote ufc-schedule.md and captured the fight card."), for: helper), "the report was refused")
        helperRunner.release.signal()
        let ended = await waitUntil(timeout: 10, pollInterval: 0.02) { !s.isRunning(helper) }
        try expect(ended, "the helper's turn did not end")
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        let woke = await waitUntil(timeout: 10, pollInterval: 0.02) {
            leadRunner.prompts.contains { $0.contains(AgentMessageEnvelope.tag) } && leadRunner.openTurns == 1
        }
        try expect(woke, "the helper's result did not wake the lead (prompts \(leadRunner.prompts.map { $0.prefix(60) }))")

        let made = [report, shot]
        func paths(_ urls: [URL?]) -> [String] { urls.compactMap { $0?.standardizedFileURL.resolvingSymlinksInPath().path } }
        func settle(_ view: ManagedAgentTileNSView, thumbs: Int) async throws -> AgentTranscriptCanvasView {
            guard let canvas = view.qaCanvasTranscript else { throw Failure(description: "the tile has no drawn transcript") }
            _ = await waitUntil(timeout: 15, pollInterval: 0.05) {
                view.layoutSubtreeIfNeeded(); canvas.flushPendingVisualUpdate(); canvas.layoutSubtreeIfNeeded()
                return canvas.qaFileThumbs.count >= thumbs && canvas.qaFileThumbs.allSatisfy(\.hasPicture)
            }
            return canvas
        }

        // The helper's own tile: its Write made the report (the first Write
        // created it; the second rewrote it) and its shell made the picture.
        let helperCanvas = try await settle(helperTile, thumbs: 2)
        let helperFiles = helperCanvas.qaChangesCards.flatMap(\.files)
        let described = { (files: [AgentDiffFileSummary]) in files.map { "\($0.displayName)[\($0.action.map { "\($0)" } ?? "-")]" } }
        try expect(helperFiles.contains { $0.fileURL?.lastPathComponent == report.lastPathComponent && $0.action == .add },
                   "the helper's tile must show the report its first Write created, got \(described(helperFiles))")
        try expect(helperFiles.contains { $0.fileURL?.lastPathComponent == shot.lastPathComponent },
                   "the helper's tile must show the picture its shell made, got \(described(helperFiles))")
        try expect(helperFiles.allSatisfy { $0.madeByAgentID == nil }, "the helper's own files carry no other agent's identity")
        print("lead-helper-files: the helper's own tile shows its created report and its shell-made picture")

        // The lead's turn: one card, both files, each with the helper's identity.
        func assertLeadCard(_ canvas: AgentTranscriptCanvasView, _ label: String) throws {
            let cards = canvas.qaChangesCards
            let files = cards.flatMap(\.files)
            try expect(cards.count == 1, "\(label): the lead's turn must draw ONE Changes card, got \(cards.map { described($0.files) })")
            try expect(Set(paths(files.map(\.fileURL))) == Set(paths(made)) && files.count == made.count,
                       "\(label): the card must hold the helper's report and picture at their real locations, got \(described(files))")
            try expect(files.allSatisfy { $0.action == .add }, "\(label): both files were created, got \(described(files))")
            try expect(files.allSatisfy { $0.madeByAgentID == helper.rawValue }, "\(label): each file must carry the helper's identity")
            let makers = canvas.qaFileThumbMakers
            try expect(makers.count == 2 && makers.allSatisfy { $0.madeBy == helper.rawValue && $0.hasOrb },
                       "\(label): each thumbnail must draw the helper's orb, got \(makers)")
            let bands = canvas.qaFileThumbText
            try expect(Set(bands.map(\.name)) == Set(made.map(\.lastPathComponent)), "\(label): the bands must name the files, got \(bands.map(\.name))")
            try expect(bands.allSatisfy { $0.facts.hasPrefix("December UFC schedule · ") },
                       "\(label): each band must name the helper that made the file, got \(bands.map(\.facts))")
            try expect(canvas.qaFileThumbs.count == 2 && canvas.qaFileThumbs.allSatisfy(\.hasPicture),
                       "\(label): both files must have a real thumbnail, got \(canvas.qaFileThumbs.map(\.hasPicture))")
        }
        // While the lead still works, and after its turn ends.
        try assertLeadCard(try await settle(leadTile, thumbs: 2), "live lead, working")
        leadRunner.end(saying: "The schedule is saved.")
        let leadDone = await waitUntil(timeout: 10, pollInterval: 0.02) { !s.isRunning(lead) }
        try expect(leadDone, "the lead's turn did not end")
        let leadCanvas = try await settle(leadTile, thumbs: 2)
        try assertLeadCard(leadCanvas, "live lead")
        print("lead-helper-files (live): the lead's turn shows the helper's report and picture, each with the helper's orb and name")
        try still(leadTile, window: leadWindow, name: "lead-live", stillsDirectory: stillsDirectory)

        // A relaunch: a second supervisor over the same stores reads the
        // delivery log back from disk; the lead's session file holds the
        // helper's result as a user message.
        let deliveries = s.helperFilesLog.deliveries(lead: lead.rawValue)
        try expect(deliveries.count == 1 && deliveries[0].files.count == 2, "the delivery must be logged with its files, got \(deliveries)")
        let relaunched = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents")),
            makeRunner: { runners[$0.record.id]! }, warn: { _ in }, nameTitlerCommand: { _ in nil },
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root.appendingPathComponent("drafts-2")),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts-2", isDirectory: true)),
            maximumActiveManagedChildren: { nil })
        _ = relaunched.restore()
        defer { relaunched.stopAll() }
        relaunched.sessionFilesHome = root
        guard var inputs = relaunched.rehydrationInputs(for: lead) else { throw Failure(description: "no rehydration inputs for the lead") }
        inputs.harness = .claudeCode
        try expect(inputs.helperDeliveries.map(\.id) == deliveries.map(\.id),
                   "the relaunched restore must read the lead's deliveries back from disk, got \(inputs.helperDeliveries.count)")
        let sessionURL = ClaudeSessionTranscriptReader.sessionFileURL(
            homeURL: root, cwd: work.path, sessionId: ManagedTranscriptRehydrator.claudeSessionId(forAgentUUID: lead.rawValue))
        try fileManager.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let envelope = AgentMessageEnvelope.wrap("December UFC schedule finished: succeeded\nWrote ufc-schedule.md.",
                                                 senderID: helper.rawValue, senderName: "December UFC schedule")
        let lines: [[String: Any]] = [
            ["type": "user", "cwd": work.path, "timestamp": formatter.string(from: deliveries[0].at.addingTimeInterval(-1)),
             "message": ["role": "user", "content": envelope]],
            ["type": "assistant", "cwd": work.path, "timestamp": formatter.string(from: deliveries[0].at.addingTimeInterval(2)),
             "message": ["role": "assistant", "content": [["type": "text", "text": "The schedule is saved."]]]],
        ]
        try lines.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n").write(to: sessionURL, atomically: true, encoding: .utf8)
        guard let restored = ManagedTranscriptRehydrator.rehydrate(inputs) else { throw Failure(description: "the lead did not rehydrate") }
        for dark in stillsDirectory == nil ? [false] : [false, true] {
            let (restoredTile, restoredWindow) = tile(lead, dark: dark)
            defer { restoredWindow.orderOut(nil) }
            restoredTile.attach(agentID: lead, supervisor: relaunched)
            restoredTile.renderRehydratedPreviousSession(restored)
            let settled = try await settle(restoredTile, thumbs: 2)
            try expect(settled.qaLaidOutText.contains("The schedule is saved."), "the restored lead's text must draw")
            try assertLeadCard(settled, "restored lead")
            try still(restoredTile, window: restoredWindow, name: "lead-restored-\(dark ? "dark" : "light")", stillsDirectory: stillsDirectory)
        }
        // A sub-helper's files roll up: the helper's own turn received them the
        // same way, so its next result carries them, still the sub-helper's.
        let subHelper = UUID()
        var tracker = AgentHelperFiles.Tracker()
        let rolled = AgentHelperFiles.Delivery(lead: helper.rawValue, helper: subHelper, at: Date(), files: [
            .init(path: shot.path, action: "add", addedLines: nil, madeBy: subHelper)])
        tracker.ingest(.toolDetail(itemId: AgentHelperFiles.itemID(rolled), detail: AgentHelperFiles.observation(rolled, at: Date())))
        let carried = tracker.take(madeBy: helper.rawValue)
        try expect(carried.count == 1 && carried[0].madeBy == subHelper && carried[0].action == "add",
                   "a sub-helper's file must roll up to the lead as the sub-helper's, got \(carried)")
        print("lead-helper-files (restore): the restored lead's turn shows the same card from the delivery log")
    }

    static func still(_ view: NSView, window: NSWindow, name: String, stillsDirectory: URL?) throws {
        guard let stillsDirectory else { return }
        try FileManager.default.createDirectory(at: stillsDirectory, withIntermediateDirectories: true)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(description: "no still") }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: stillsDirectory.appendingPathComponent("\(name).png"))
    }
}
#endif
