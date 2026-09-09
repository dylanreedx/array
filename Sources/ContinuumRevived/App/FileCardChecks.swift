import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Ticket: TR-01 — file cards and reliable diff counts.
//
// The reported card said "0 files · line counts unavailable" under an absolute
// path it had just printed. That combination is only producible one way: the
// row came back from a RESTORED session, where the file facts never reached the
// host-local detail store at all, and the renderer then reported the empty list
// as a measurement of zero.
//
// So the first witness drives the restore path end to end — the same method the
// tile calls on attach — and reads the sentence off a real card. The second
// pins that two edits to one path stay two cards. The third is the honesty
// table for every state a count can be in.
@MainActor
enum FileCardChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func fail(_ message: String) -> Failure { Failure(description: message) }

    static func run() async throws {
        try await checkRestoredEditCardNamesItsFileAndCounts()
        try await checkTwoEditsToOnePathStayTwoCards()
        try checkCountsNeverClaimUnmeasuredPrecision()
        print("ContinuumRevivedFileCardChecks passed: a restored edit names its file and its measured counts, two edits to one path stay two cards, and no card reports a count it did not measure")
    }

    /// One assistant turn that edits one file, in claude's real session-file
    /// shape, plus the tool_result that completes it.
    private static func claudeSessionLines(
        toolUseID: String, path: String, old: String, new: String
    ) -> [String] {
        [
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"do the thing"}}"#,
            """
            {"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":\
            [{"type":"tool_use","id":"\(toolUseID)","name":"Edit","input":\
            {"file_path":"\(path)","old_string":"\(old)","new_string":"\(new)"}}]}}
            """,
            """
            {"type":"user","isSidechain":false,"message":{"role":"user","content":\
            [{"tool_use_id":"\(toolUseID)","type":"tool_result","is_error":false,"content":"ok"}]}}
            """,
        ]
    }

    /// One operation reaches the detail store as SEVERAL writes — the item's own
    /// start, then each parked observation, then the end — every one on its own
    /// detached task, each scheduling its own presentation refresh. The file
    /// list arrives with the activity observation and the COUNTS one write
    /// later, so a witness that samples at the first non-empty result reads a
    /// half-built record and a witness that spins without yielding real time
    /// sees that half-built state hold still.
    ///
    /// Wait for the presented payloads to stop moving, with a real deadline, and
    /// say so out loud if they never do.
    private static func settle(_ tile: ManagedAgentTileNSView) async throws {
        func snapshot() -> [AgentDiffPayload] {
            diffBlocks(tile).compactMap {
                tile.qaTranscriptForChecks?.qaPresentedDiffPayload(for: $0.blockID)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        var previous = snapshot()
        var stableRounds = 0
        while Date() < deadline {
            await tile.qaTranscriptForChecks?.qaWaitForToolDetailRefresh()
            try? await Task.sleep(nanoseconds: 5_000_000)
            let current = snapshot()
            stableRounds = current == previous ? stableRounds + 1 : 0
            previous = current
            // ~100ms of no movement, after the async write/refresh chain has had
            // real time to run.
            if stableRounds >= 20 { return }
        }
        throw fail("settle: the presented change cards never stopped changing within 5s")
    }

    private static func makeTile(_ title: String) -> ManagedAgentTileNSView {
        ManagedAgentTileNSView(tile: Tile(
            id: UUID(),
            kind: .managedAgent,
            title: title,
            frame: TileFrame(x: 0, y: 0, width: 560, height: 420),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        ))
    }

    /// The diff blocks this tile's document holds, in order, with the provider
    /// item each came from.
    private static func diffBlocks(
        _ tile: ManagedAgentTileNSView
    ) -> [(itemID: String, blockID: AgentNodeID)] {
        tile.qaDocumentForChecks.entries.compactMap { entry in
            guard case let .providerItem(_, itemID?) = entry.provenance,
                  let block = entry.blocks.first(where: { $0.kind == .diff })
            else { return nil }
            return (itemID: itemID, blockID: block.id)
        }
    }

    /// RED before this ticket: the restored card presented ZERO files, because
    /// `renderRehydratedPreviousSession` ingested straight into the model and
    /// never crossed the host-local capture seam the live path uses. The count
    /// half was red for every provider and every path — nothing in the app
    /// computed one.
    private static func checkRestoredEditCardNamesItsFileAndCounts() async throws {
        let tile = makeTile("tr01-restored")
        // The order attach uses: identity first, then the restored history.
        tile.qaTranscriptForChecks?.bindToolDetailAgent(AgentID(rawValue: UUID()))
        // "one\ntwo" → "one\nTWO\nthree" is +2 −1 once the shared first line is
        // peeled off — the count git would report for this hunk.
        let transcript = ClaudeSessionTranscriptReader.parse(
            lines: claudeSessionLines(
                toolUseID: "toolu_restored",
                path: "/repo/Sources/App/Main.swift",
                old: "one\\ntwo", new: "one\\nTWO\\nthree"),
            threadId: tile.qaThreadIdForChecks)
        tile.renderRehydratedPreviousSession(transcript)
        try await settle(tile)

        let blocks = diffBlocks(tile)
        guard blocks.count == 1, let blockID = blocks.first?.blockID else {
            throw fail("restored edit: expected exactly one change card, got \(blocks.count)")
        }
        guard let payload = tile.qaTranscriptForChecks?.qaPresentedDiffPayload(for: blockID) else {
            throw fail("restored edit: the card presented no diff payload at all")
        }
        guard payload.files.count == 1, let file = payload.files.first else {
            throw fail(
                "restored edit: the card knows about \(payload.files.count) files — the restored "
                + "path never reached the host-local detail store (this is the reported bug)"
            )
        }
        guard file.displayName == "…/App/Main.swift" else {
            throw fail("restored edit: expected the abbreviated host-local path, got '\(file.displayName)'")
        }
        guard file.addedLineCount == 2, file.removedLineCount == 1 else {
            throw fail(
                "restored edit: expected the measured +2 −1 this edit performed, got "
                + "+\(String(describing: file.addedLineCount)) −\(String(describing: file.removedLineCount))"
            )
        }
        // The sentence the user actually reads, off the real card.
        let card = AgentDiffSummaryView()
        card.frame = NSRect(x: 0, y: 0, width: 520, height: 160)
        card.apply(
            blockID: blockID, payload: payload,
            context: AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark))
        card.layoutSubtreeIfNeeded()
        guard card.countsLabel.stringValue == "1 file · +2 −1" else {
            throw fail("restored edit: the card reads '\(card.countsLabel.stringValue)'")
        }
        // The absolute path belongs to the file row and the host-local record —
        // never to the document, which the live path is careful to keep clean.
        guard card.summaryLabel.stringValue == "Edit",
              !(payload.summary ?? "").contains("/repo/") else {
            throw fail(
                "restored edit: the absolute path is still riding the document's title "
                + "('\(payload.summary ?? "")') — it prints twice and it should not be there"
            )
        }
    }

    /// Two Edit calls on ONE path are two operations, and a card each. Identity
    /// is the provider item, never the path: collapsing by path would erase a
    /// real edit, and it is the shape the reported screenshot actually showed.
    private static func checkTwoEditsToOnePathStayTwoCards() async throws {
        let tile = makeTile("tr01-repeat")
        tile.qaTranscriptForChecks?.bindToolDetailAgent(AgentID(rawValue: UUID()))
        let path = "/repo/Sources/App/Main.swift"
        let transcript = ClaudeSessionTranscriptReader.parse(
            lines: claudeSessionLines(
                toolUseID: "toolu_first", path: path, old: "alpha", new: "ALPHA")
                + claudeSessionLines(
                    toolUseID: "toolu_second", path: path,
                    old: "beta", new: "BETA\\ngamma"),
            threadId: tile.qaThreadIdForChecks)
        tile.renderRehydratedPreviousSession(transcript)
        try await settle(tile)

        let blocks = diffBlocks(tile)
        guard blocks.count == 2 else {
            throw fail(
                "repeated edits: two edits to one path must stay two cards, got \(blocks.count)")
        }
        guard Set(blocks.map(\.itemID)) == ["toolu_first", "toolu_second"] else {
            throw fail("repeated edits: cards lost their provider identity: \(blocks.map(\.itemID))")
        }
        let presented = blocks.compactMap {
            tile.qaTranscriptForChecks?.qaPresentedDiffPayload(for: $0.blockID)
        }
        guard presented.count == 2,
              presented.allSatisfy({ $0.files.map(\.displayName) == ["…/App/Main.swift"] }) else {
            throw fail("repeated edits: each card must name the file it changed: \(presented.map(\.files))")
        }
        // Per-operation counts: the first replaced one line, the second turned
        // one line into two. Neither card may show the other's work, and no
        // card may show the file's total.
        guard presented[0].files[0].addedLineCount == 1, presented[0].files[0].removedLineCount == 1,
              presented[1].files[0].addedLineCount == 2, presented[1].files[0].removedLineCount == 1 else {
            throw fail(
                "repeated edits: counts are per OPERATION, got "
                + presented.map { "\(String(describing: $0.files[0].addedLineCount))/\(String(describing: $0.files[0].removedLineCount))" }
                    .joined(separator: " and ")
            )
        }
    }

    /// The honesty table. Every one of these was "0 files · line counts
    /// unavailable" or a fabricated "+0 −0" before.
    private static func checkCountsNeverClaimUnmeasuredPrecision() throws {
        func card(_ payload: AgentDiffPayload) -> AgentDiffSummaryView {
            let view = AgentDiffSummaryView()
            view.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
            view.apply(
                blockID: AgentNodeID(rawValue: "tr01-states")!, payload: payload,
                context: AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark))
            view.layoutSubtreeIfNeeded()
            return view
        }

        // An empty list is NOT a measurement of zero.
        var pending = AgentDiffPayload(text: "edit", summary: "Edit")
        pending.presentedFilesArePending = true
        guard card(pending).countsLabel.stringValue == "Working…" else {
            throw fail("pending: a running operation reads '\(card(pending).countsLabel.stringValue)'")
        }
        let unrecorded = AgentDiffPayload(text: "edit", summary: "Edit")
        guard card(unrecorded).countsLabel.stringValue == "Files not recorded" else {
            throw fail(
                "unrecorded: an empty list must not be reported as a measured zero, got "
                + "'\(card(unrecorded).countsLabel.stringValue)'"
            )
        }

        // Named file, no counts — the pre-existing honest case, unchanged.
        let named = AgentDiffPayload(
            text: "edit", summary: "Edit", files: [.init(displayName: "a.swift")])
        guard card(named).countsLabel.stringValue == "1 file · line counts unavailable",
              card(named).fileStatLabels.first?.stringValue == "counts unavailable" else {
            throw fail("named-only: '\(card(named).countsLabel.stringValue)'")
        }

        // A delete says what it did rather than inventing "−0".
        let deleted = AgentDiffPayload(
            text: "edit", summary: "Edit",
            files: [.init(displayName: "gone.swift", action: .delete)])
        guard card(deleted).fileStatLabels.first?.stringValue == "deleted" else {
            throw fail("delete: '\(card(deleted).fileStatLabels.first?.stringValue ?? "missing")'")
        }

        // Half measured: a whole-file write knows its additions and cannot know
        // what it replaced. The aggregate is then a FLOOR, and says so.
        let write = AgentDiffPayload(
            text: "write", summary: "Write",
            files: [.init(displayName: "new.swift", addedLineCount: 12, action: .write)])
        guard card(write).fileStatLabels.first?.stringValue == "+12 −?" else {
            throw fail("write: '\(card(write).fileStatLabels.first?.stringValue ?? "missing")'")
        }
        guard card(write).countsLabel.stringValue == "1 file · ≥ +12 −0" else {
            throw fail("write aggregate: '\(card(write).countsLabel.stringValue)'")
        }

        // Counts taken from a truncated preview are a floor too.
        let truncated = AgentDiffPayload(
            text: "edit", summary: "Edit",
            files: [.init(
                displayName: "big.swift", addedLineCount: 80, removedLineCount: 0,
                countsAreLowerBound: true, action: .edit)])
        guard card(truncated).countsLabel.stringValue == "1 file · ≥ +80 −0" else {
            throw fail("truncated: '\(card(truncated).countsLabel.stringValue)'")
        }

        // Fully measured, including a real measured ZERO — which is a fact, and
        // must still be printed as one.
        let measured = AgentDiffPayload(
            text: "edit", summary: "Edit",
            files: [
                .init(displayName: "a.swift", addedLineCount: 3, removedLineCount: 1, action: .edit),
                .init(displayName: "b.swift", addedLineCount: 0, removedLineCount: 0, action: .edit),
            ])
        guard card(measured).countsLabel.stringValue == "2 files · +3 −1" else {
            throw fail("measured: '\(card(measured).countsLabel.stringValue)'")
        }
        guard card(measured).fileStatLabels.dropFirst().first?.stringValue == "+0 −0" else {
            throw fail("measured zero: a measured +0 −0 is a fact and must be printed")
        }

        // Mixed: some measured, some not. The card names both halves.
        let mixed = AgentDiffPayload(
            text: "edit", summary: "Edit",
            files: [
                .init(displayName: "a.swift", addedLineCount: 3, removedLineCount: 1, action: .edit),
                .init(displayName: "b.swift", action: .edit),
            ])
        guard card(mixed).countsLabel.stringValue == "2 files · +3 −1 · 1 file without counts" else {
            throw fail("mixed: '\(card(mixed).countsLabel.stringValue)'")
        }
    }
}
