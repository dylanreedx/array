import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// The dead-air witness.
//
// The complaint this guards is "I send a message and nothing happens for
// seconds". Two separate causes produced it, and only one of them was latency:
//
//  1. The transcript echoed the user's own prompt only AFTER
//     `supervisor.accept` returned, which put it behind a main-actor hop, a
//     draft-journal read and write, a blocking cross-process flock on the agent
//     store, and (for pi) a scan of `.pi/agents`.
//  2. The tile had no state for the spawn window, so it presented "idle" with a
//     disabled composer and no clock while a CLI process was starting — and
//     while `canStop` was already true.
//
// Both are regressions you cannot see in a screenshot of a finished turn, and
// neither shows up as a failed turn. So they are asserted as ORDERING, not as
// elapsed time: per docs/internals/performance.md, assert the work, not the
// clock. A stopwatch here would be a weak witness on a loaded machine; "the
// echo happened before the sink was ever entered" cannot be satisfied by a
// fast machine.
enum AgentFirstPaintChecks {
    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func fail(_ message: String) -> CheckFailure {
        CheckFailure(description: message)
    }

    /// A sink that records the order of what happened to it and can be held
    /// open, so "before the sink finished" is observable rather than timed.
    @MainActor
    private final class OrderRecordingSink: AgentTileActionSink {
        private(set) var acceptEntered = false
        private(set) var events: [String] = []
        private(set) var receivedIntents: [AgentComposerIntent] = []
        private let acceptance: IntentAcceptance
        private let hold: (@MainActor () async -> Void)?

        init(_ acceptance: IntentAcceptance, hold: (@MainActor () async -> Void)? = nil) {
            self.acceptance = acceptance
            self.hold = hold
        }

        func note(_ event: String) { events.append(event) }

        func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance {
            acceptEntered = true
            receivedIntents.append(intent)
            events.append("accept-entered")
            await hold?()
            events.append("accept-returned")
            return acceptance
        }
    }

    @MainActor
    static func run() throws {
        try checkEchoPrecedesTheSink()
        try checkRefusalIsSaidOutLoud()
        try checkOptimisticWindowSurvivesSynchronize()
        try checkSettledTailStatus()
        try checkReplyOptionsReachTheComposer()
        try checkAttachmentMidTurnUsesWorkingDraftIntent()
        try checkPopoverCommandEchoesLikeATypedSend()
        try checkMirroredAgentOffersNoComposerOrStop()
        try checkStreamingResponseKeepsALivenessSignal()
        try checkAStreamingChunkDoesNotWalkTheWholeTranscript()
        print("ContinuumRevivedAgentFirstPaintChecks passed: the prompt echo precedes the action sink, acceptance and refusal both resolve the latch, the spawn window carries a state, a word, and a clock, the optimistic indicator survives synchronize, settled turns read their duration, a mid-turn attachment resolves honestly instead of forcing sendPrompt, and a popover-selected command echoes exactly like a typed one, an agent Array only mirrors offers no composer, no provider controls and no Stop, and a streaming response keeps a liveness signal instead of going dead")
    }

    /// `.plans/45` S6 (C4). `beginOptimisticSubmission` turns the indicator on
    /// with the keystroke; the next transcript synchronize re-derives visibility
    /// from `descriptor.status == .working` — which has NOT flipped yet — and
    /// used to stomp it off. That gap is "blank for a while after sending".
    @MainActor
    private static func checkOptimisticWindowSurvivesSynchronize() throws {
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(),
            kind: .managedAgent,
            title: "first-paint-optimistic",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 420),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        ))
        guard !tile.qaThinkingIndicatorVisible else {
            throw fail("optimistic window: the indicator was on before anything was sent")
        }
        tile.qaBeginOptimisticSubmissionForChecks("do the thing")
        guard tile.qaThinkingIndicatorVisible else {
            throw fail("optimistic window: sending did not turn the indicator on with the keystroke")
        }
        // The REAL re-derivation, with the descriptor still not .working —
        // exactly the state the first stream event finds.
        tile.qaRefreshThinkingIndicatorForChecks()
        guard tile.qaThinkingIndicatorVisible else {
            throw fail(
                "optimistic window: the synchronize path stomped the optimistic indicator off "
                + "before the provider ever reported working — the blank-after-send bug (C4)"
            )
        }
    }

    /// `.plans/45` S6 (Dylan's design 3): a settled turn reads "Worked for Ns"
    /// on the tail — gyro gone, words kept — and the next send reclaims the row.
    @MainActor
    private static func checkSettledTailStatus() throws {
        for (interval, expected) in [(4.32, "4.3s"), (9.97, "10s"), (42.4, "42s"), (75.0, "1m 15s"), (180.0, "3m")] {
            let got = ManagedAgentTileNSView.settledDurationText(interval)
            guard got == expected else {
                throw fail("settled duration: \(interval) rendered as \(got), expected \(expected)")
            }
        }
        let list = AgentTranscriptListView()
        list.setSettledTailStatus("Worked for 27s")
        guard list.qaTailStatusText == "Worked for 27s", list.qaTailIsSettled,
              !list.qaThinkingIndicatorVisible else {
            throw fail(
                "settled tail: expected the words without the gyro, got text "
                + "'\(list.qaTailStatusText)', settled \(list.qaTailIsSettled), "
                + "gyro \(list.qaThinkingIndicatorVisible)"
            )
        }
        list.setThinkingIndicatorVisible(true)
        guard list.qaThinkingIndicatorVisible, !list.qaTailIsSettled else {
            throw fail("settled tail: the next turn did not reclaim the tail row for the gyro")
        }
    }

    /// Dylan's ask: "selecting options rather than typing options."
    ///
    /// The detector has its own pure leg in `ContinuumRevivedAgentContentChecks`.
    /// This is the half that leg cannot see: that a REAL turn, arriving as real
    /// runtime events, actually puts chips in front of the user — and that
    /// pressing one writes text and sends nothing. A detector that is perfect
    /// while nothing renders is the exact failure the tool-detail vocabulary
    /// spent months in.
    @MainActor
    private static func checkReplyOptionsReachTheComposer() throws {
        let thread = "thread-main"
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(),
            kind: .managedAgent,
            title: "reply-options",
            frame: TileFrame(x: 0, y: 0, width: 560, height: 460),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        ))
        tile.layoutSubtreeIfNeeded()

        guard tile.qaReplyOptionChipTitles.isEmpty else {
            throw fail("reply options: an untouched tile already offered \(tile.qaReplyOptionChipTitles)")
        }

        let reply = """
            Two ways to do this. Which do you want?

            - Rewrite the resolver — keeps the API
            - Patch the call sites — smaller diff
            """
        tile.ingest(.turnStarted(threadId: thread, turnId: "turn-1"))
        tile.ingest(.contentDelta(
            threadId: thread, turnId: "turn-1", streamKind: .assistant, delta: reply
        ))

        // Mid-turn the offer must not appear: the list is still being written.
        guard tile.qaReplyOptionChipTitles.isEmpty else {
            throw fail(
                "reply options: chips appeared while the turn was still streaming "
                + "(\(tile.qaReplyOptionChipTitles)) — they would flicker through every "
                + "intermediate list the stream writes"
            )
        }

        tile.ingest(.turnCompleted(
            threadId: thread, turnId: "turn-1", outcome: .completed, errorMessage: nil
        ))
        tile.layoutSubtreeIfNeeded()
        let offered = tile.qaReplyOptionChipTitles
        guard offered == ["Rewrite the resolver", "Patch the call sites"] else {
            throw fail(
                "reply options: a settled turn that asked and listed offered \(offered) — the "
                + "reader still has to type the answer to a question the reply already enumerated"
            )
        }

        guard tile.qaPressReplyOptionChip(titled: "Patch the call sites") else {
            throw fail("reply options: the chip was not a pressable control")
        }
        guard tile.qaComposerDraftText == "Patch the call sites" else {
            throw fail(
                "reply options: pressing a chip left the composer reading "
                + "'\(tile.qaComposerDraftText)'"
            )
        }
        // Nothing was SENT. A chip is a composer shortcut; the user still sends,
        // so a wrong detection costs a word to delete rather than a turn. A send
        // would have lit the optimistic indicator in the same frame (S6/C4) —
        // that is the production tell, so it is what this reads.
        guard !tile.qaThinkingIndicatorVisible else {
            throw fail(
                "reply options: pressing a chip started a turn — a detected offer must never "
                + "dispatch on the user's behalf"
            )
        }
        // And the offer withdraws now that a draft exists, rather than sitting
        // there ready to overwrite what the user is writing.
        guard tile.qaReplyOptionChipTitles.isEmpty else {
            throw fail(
                "reply options: the chips stayed up over a non-empty draft "
                + "(\(tile.qaReplyOptionChipTitles)) — pressing one would replace the user's text"
            )
        }
    }

    /// THE assertion: acknowledgement is a function of the keystroke, not of how
    /// long anything downstream takes.
    @MainActor
    private static func checkEchoPrecedesTheSink() throws {
        let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        composer.apply(.init(text: "ship the transcript", selection: NSRange(location: 19, length: 0), revision: 1))
        let sink = OrderRecordingSink(.accepted)
        var startedWith: AgentPrompt?
        composer.onSubmissionStarted = { prompt in
            startedWith = prompt
            sink.note("echo-painted")
        }
        composer.bindActionSink(sink, agentID: AgentID(rawValue: UUID()), snapshot: .init(
            state: .ready,
            capabilities: .sendStop(canSend: true, canStop: false),
            turnStartedAt: nil
        ))

        composer.composerRequestedSend(composer.textView)

        // Synchronously, in the same call — not "eventually". `composerRequestedSend`
        // has returned and the sink has not been touched, so no amount of local IO
        // or provider latency can be in front of the echo.
        guard let startedWith else {
            throw fail("first-paint: submitting did not paint the prompt at all — onSubmissionStarted never fired")
        }
        guard startedWith.text == "ship the transcript" else {
            throw fail("first-paint: the echoed prompt was \(startedWith.text), not what the user typed")
        }
        guard !sink.acceptEntered else {
            throw fail("first-paint: the action sink was entered before the prompt was painted — the echo is behind the submission path again, which is the original dead-air bug")
        }
        guard sink.events.first == "echo-painted" else {
            throw fail("first-paint: expected the echo first, got \(sink.events)")
        }
    }

    /// The other half of an optimistic paint: if the submission does NOT happen,
    /// the tile has to say so. Otherwise the fix trades dead air for a prompt on
    /// screen that never ran, which is worse.
    @MainActor
    private static func checkRefusalIsSaidOutLoud() throws {
        let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        composer.apply(.init(text: "this will be refused", selection: NSRange(location: 20, length: 0), revision: 1))
        let sink = OrderRecordingSink(.refused(.turnNotReady))
        var resolutions: [Bool] = []
        composer.onSubmissionStarted = { _ in }
        composer.onSubmissionFinished = { resolutions.append($0) }
        composer.bindActionSink(sink, agentID: AgentID(rawValue: UUID()), snapshot: .init(
            state: .ready,
            capabilities: .sendStop(canSend: true, canStop: false),
            turnStartedAt: nil
        ))

        composer.composerRequestedSend(composer.textView)
        let deadline = Date().addingTimeInterval(2)
        while resolutions.isEmpty && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard resolutions == [false] else {
            throw fail("first-paint: a refused submission resolved \(resolutions) — an unresolved latch leaves an optimistic prompt on screen claiming to have been sent")
        }
        guard composer.textView.string == "this will be refused" else {
            throw fail("first-paint: a refused submission lost the user's draft (\(composer.textView.string))")
        }
    }

    /// `.plans/45` fix 1: an attachment used to force `.sendPrompt` regardless of
    /// `executionState`, so attaching a file mid-turn was refused as
    /// `.turnNotReady` and the optimistic bubble rolled back — silently losing
    /// the message. The intent must be computed honestly (working-draft
    /// steer/queue) instead of overridden by the presence of an attachment.
    @MainActor
    private static func checkAttachmentMidTurnUsesWorkingDraftIntent() throws {
        let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        composer.apply(.init(text: "steer this turn", selection: NSRange(location: 16, length: 0), revision: 1))

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-paint-attachment-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tempURL.path, contents: Data("hi".utf8))
        defer { try? FileManager.default.removeItem(at: tempURL) }
        composer.qaAddFileReferenceForChecks(AgentPromptFileReference(
            displayName: "note.txt", contentType: "text/plain", fileURL: tempURL
        ))

        let sink = OrderRecordingSink(.accepted)
        composer.bindActionSink(sink, agentID: AgentID(rawValue: UUID()), snapshot: .init(
            state: .working,
            capabilities: AgentTurnCapabilities(canSend: false, canStop: true, canSteer: true, canQueue: false),
            turnStartedAt: Date()
        ))

        composer.composerRequestedSend(composer.textView)

        let deadline = Date().addingTimeInterval(2)
        while sink.receivedIntents.isEmpty && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard let intent = sink.receivedIntents.first else {
            throw fail("attachment mid-turn: composerRequestedSend produced no intent at all — an attachment must still route to the sink while a turn is working")
        }
        guard case let .steer(prompt) = intent else {
            throw fail(
                "attachment mid-turn: expected the working-draft intent (.steer), got \(intent) — "
                + "an attachment forced .sendPrompt while a turn was running, which the supervisor "
                + "refuses as .turnNotReady and rolls back the optimistic bubble"
            )
        }
        guard prompt.text == "steer this turn", prompt.fileReferences.count == 1 else {
            throw fail("attachment mid-turn: the resolved steer intent lost the draft text or the attachment")
        }
    }

    /// `.plans/45` fix 2a: a command chosen from the completion popover
    /// dispatched straight to `onCompletionAction` and never painted the same
    /// optimistic echo a typed-and-sent command gets from `submitBoundIntent`.
    /// Invoking the identical command two ways therefore looked different: an
    /// immediate bubble for one, silence for the other.
    @MainActor
    private static func checkPopoverCommandEchoesLikeATypedSend() throws {
        let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        var echoed: [AgentPrompt] = []
        composer.onSubmissionStarted = { echoed.append($0) }
        composer.onCompletionAction = { _ in true }

        let invocation = AgentCommandInvocation(
            descriptorID: "array.compact",
            name: "compact",
            arguments: ["now"],
            surface: .array
        )
        let completion = AgentCompletion(
            id: "array.compact",
            title: "compact",
            insertionText: "/compact",
            payload: .command(invocation)
        )
        composer.qaAcceptCompletionForChecks(completion, replacementRange: NSRange(location: 0, length: 0))

        guard let echo = echoed.first else {
            throw fail("popover command echo: selecting a command from the completion popover painted no optimistic echo at all — invoking the same command by typing it does")
        }
        guard echo.text == "/compact now" else {
            throw fail("popover command echo: expected the same text a typed send would have shown ('/compact now'), got '\(echo.text)'")
        }
    }

    /// The spawn window is a real state, with the word and the clock to match.
    ///
    /// Pure over the presenter, because the interesting failure is not "the
    /// process was slow" but "the app had nothing to say about it".
    @MainActor
    static func checkSpawnWindowIsPresentable() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let spawning = AgentTileTurnSnapshot(
            state: .starting,
            capabilities: .sendStop(canSend: false, canStop: true),
            turnStartedAt: nil,
            submittedAt: now.addingTimeInterval(-4)
        )
        let presented = AgentTileStatePresenter.present(
            name: "Spawning", snapshot: spawning, branchContext: nil,
            startedAt: nil, now: now
        )
        guard presented.stateLabel == AgentStatusVocabulary.starting else {
            throw fail("first-paint: the spawn window reads \(presented.stateLabel), not \(AgentStatusVocabulary.starting) — this is the window that used to say idle")
        }
        guard presented.elapsedSeconds == 4 else {
            throw fail("first-paint: the spawn window measures \(String(describing: presented.elapsedSeconds))s, expected 4 from the submission — an unclocked spawn is indistinguishable from a hung one")
        }
        guard presented.status == .working else {
            throw fail("first-paint: the spawn window presents status \(presented.status), which paints no motion while a process is starting")
        }
    }
}

extension AgentFirstPaintChecks {
    /// C5 — an agent Array MIRRORS must not offer a composer, provider controls
    /// or a Stop.
    ///
    /// A claude `Agent` subagent has no process of Array's. Rendering an enabled
    /// Stop over one is exactly the dishonesty this program exists to remove, and
    /// a merely DISABLED composer is still wrong: disabled says try later, and
    /// there is no later.
    ///
    /// Drives the real tile's own presentation update through a real
    /// `AgentTileTurnSnapshot`, the same value `AgentSupervisor.turnSnapshot(for:)`
    /// produces — a check that re-derived the decision itself would pass while the
    /// tile still painted the controls.
    @MainActor
    static func checkMirroredAgentOffersNoComposerOrStop() throws {
        func makeTile(_ title: String) -> ManagedAgentTileNSView {
            ManagedAgentTileNSView(tile: Tile(
                id: UUID(),
                kind: .managedAgent,
                title: title,
                frame: TileFrame(x: 0, y: 0, width: 520, height: 420),
                zPosition: .fromLegacyRank(1),
                runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed")
            ))
        }

        // An ordinary managed agent, idle: the controls ARE offered. Without this
        // half the assertion below would pass over a tile that never shows a
        // composer at all.
        let managed = makeTile("mirrored-check-managed")
        managed.qaApplyTurnSnapshotForChecks(AgentTileTurnSnapshot(
            state: .ready,
            capabilities: .sendStop(canSend: true, canStop: false),
            turnStartedAt: nil))
        guard managed.qaComposerIsOffered, managed.qaProviderControlsAreOffered else {
            throw fail("mirrored: an ordinary managed agent stopped offering its composer/provider controls — the positive half of this witness is what keeps the negative half meaningful")
        }

        let mirrored = makeTile("mirrored-check-observed")
        mirrored.qaApplyTurnSnapshotForChecks(AgentTileTurnSnapshot(
            state: .working,
            capabilities: .sendStop(canSend: false, canStop: false),
            turnStartedAt: Date(),
            isMirrored: true))
        guard !mirrored.qaComposerIsOffered else {
            throw fail("mirrored: the tile offers a composer for an agent Array does not run")
        }
        guard !mirrored.qaProviderControlsAreOffered else {
            throw fail("mirrored: the tile offers provider/model/effort controls and a Stop for an agent Array does not run")
        }
    }

    /// Dylan, driving the build: "the response looks dead... there is no
    /// indicator that the response is streaming in."
    ///
    /// The transcript has exactly ONE animated element — the gyro on the tail —
    /// and `showsWorkingTail` used to switch it off the moment the last entry
    /// became an open assistant entry, i.e. for the whole answer. Nothing
    /// replaced it, because the compact status row is deliberately silent for
    /// exactly those live phases on the grounds that the gyro carries them.
    ///
    /// This asserts the DECISION, not the animation, and it has to.
    /// `AgentTranscriptMotion.isEnabled` defaults to false and production flips
    /// it once at launch, so every check leg — and every pixel baseline — sees a
    /// motionless transcript. No screenshot gate could ever have caught this, and
    /// that is why it shipped.
    /// A streaming chunk must not cost the whole conversation — asserted through
    /// the TILE, which is the only thing that streams.
    ///
    /// `--perf-budget-transcript-delta-check` drives `AgentTranscriptListView`
    /// directly, so it can only ever be as faithful as the patch the scenario
    /// chooses to hand it. For most of its life it handed a node-level patch to
    /// `apply(document:patch:)` — a method with ZERO production callers — while a
    /// real tile enqueued an EMPTY patch and took the full walk on every token.
    /// The gate reported 5.5ms; production cost 93ms at 10,000 rows.
    ///
    /// This check exists so that divergence cannot recur silently: it ingests
    /// real events into a real tile and asserts, on the tile's own transcript,
    /// that the streaming path stayed local. No fixture chooses the patch here —
    /// the tile does, exactly as it does in the field.
    @MainActor
    private static func checkAStreamingChunkDoesNotWalkTheWholeTranscript() throws {
        let thread = "thread-main"
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "streaming-locality",
            frame: TileFrame(x: 0, y: 0, width: 560, height: 460),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.layoutSubtreeIfNeeded()

        // Build a conversation with real history: 40 completed turns, each a user
        // prompt and an assistant reply. History is the variable the whole
        // contract is about, so a fixture without it proves nothing.
        for turn in 0..<40 {
            tile.ingest(.turnStarted(threadId: thread, turnId: "turn-\(turn)"))
            tile.ingest(.contentDelta(
                threadId: thread, turnId: "turn-\(turn)", streamKind: .assistant,
                delta: "Answer number \(turn), long enough to be a real row of prose."))
            tile.ingest(.turnCompleted(
                threadId: thread, turnId: "turn-\(turn)", outcome: .completed, errorMessage: nil))
        }
        guard let transcript = tile.qaTranscriptForChecks else {
            throw fail("streaming locality: the tile has no transcript to measure")
        }
        tile.qaFlushStreamingMarkupForChecks()
        transcript.flushPendingVisualUpdate()

        // The fixture's own teeth: there must actually BE history to walk.
        guard transcript.qaSemanticRowCount >= 40 else {
            throw fail(
                "streaming locality: the fixture built only \(transcript.qaSemanticRowCount) rows, "
                + "so a whole-history walk would be indistinguishable from a local one"
            )
        }
        let history = transcript.qaSemanticRowCount

        // Present whatever has been ingested, through the REAL forwarding path.
        //
        // `tile.ingest` alone presents nothing: streaming markup is parsed on a
        // debounce timer, and only `synchronizeV2Transcript` forwards to the
        // transcript. Flushing the list's visual scheduler without firing that
        // timer measures an empty queue — which is exactly how the first draft of
        // this check passed with the fix reverted.
        func present() {
            tile.qaFlushStreamingMarkupForChecks()
            transcript.flushPendingVisualUpdate()
        }

        // Now stream one more answer, chunk by chunk, and measure ONLY that.
        //
        // The FIRST chunk of a turn is structural — it begins the assistant entry
        // and its markup block — and a structural step legitimately rebuilds the
        // row index. That is a cost per TURN, which is fine. The contract being
        // asserted is that it is not a cost per TOKEN, which is what a streaming
        // answer produces hundreds of.
        tile.ingest(.turnStarted(threadId: thread, turnId: "turn-live"))
        tile.ingest(.contentDelta(
            threadId: thread, turnId: "turn-live", streamKind: .assistant, delta: "opening "))
        present()
        transcript.qaResetFlattenStats()
        let visualAppliesBefore = transcript.qaVisualApplyCount
        let chunks = 12
        for chunk in 0..<chunks {
            tile.ingest(.contentDelta(
                threadId: thread, turnId: "turn-live", streamKind: .assistant,
                delta: "chunk \(chunk) "))
            // Present every chunk. Letting the 30Hz scheduler coalesce would
            // measure a fraction of them and call the rest free.
            present()
        }

        // POSITIVE CONTROL, and the reason this check can be trusted at all.
        // Every count budget below is satisfied perfectly by a transcript that
        // presented NOTHING, so the first thing to establish is that the chunks
        // reached the renderer.
        let presented = transcript.qaVisualApplyCount - visualAppliesBefore
        guard presented >= chunks else {
            throw fail(
                "streaming locality: \(chunks) chunks produced only \(presented) presentations, so "
                + "the zeroes below measure an empty queue rather than a cheap one"
            )
        }

        guard transcript.qaFullFlattenCount == 0 else {
            throw fail(
                "streaming locality: \(chunks) chunks INSIDE an already-open answer caused "
                + "\(transcript.qaFullFlattenCount) whole-document rebuilds over \(history) rows of "
                + "history — the tile is not telling the transcript what changed, so every token "
                + "re-indexes the entire conversation"
            )
        }
        guard transcript.qaHistoryScanCount == 0 else {
            throw fail(
                "streaming locality: \(chunks) streaming chunks walked the applied history "
                + "\(transcript.qaHistoryScanCount) times over \(history) rows"
            )
        }
        // Cheap and WRONG is the failure a cost witness cannot see, so the rows
        // are checked against a from-scratch walk of the same document.
        if let mismatch = transcript.qaIndexEquivalenceMismatch(for: tile.qaDocumentForChecks) {
            throw fail(
                "streaming locality: the incremental rows diverged from a full walk — \(mismatch)"
            )
        }
        // And the per-turn cost is bounded too, so this cannot be satisfied by
        // moving the walk somewhere the measurement above does not look.
        transcript.qaResetFlattenStats()
        for turn in 100..<104 {
            tile.ingest(.turnStarted(threadId: thread, turnId: "turn-\(turn)"))
            for chunk in 0..<8 {
                tile.ingest(.contentDelta(
                    threadId: thread, turnId: "turn-\(turn)", streamKind: .assistant,
                    delta: "chunk \(chunk) "))
                present()
            }
            tile.ingest(.turnCompleted(
                threadId: thread, turnId: "turn-\(turn)", outcome: .completed, errorMessage: nil))
            present()
        }
        // 4 turns × 8 chunks = 32 presented steps. A handful of structural walks
        // is the entry and block each turn begins; anything approaching 32 is the
        // per-token regression this exists to catch.
        guard transcript.qaFullFlattenCount <= 12 else {
            throw fail(
                "streaming locality: 4 turns of 8 chunks each cost "
                + "\(transcript.qaFullFlattenCount) whole-document rebuilds — a walk per turn is "
                + "the structural cost of opening an entry, a walk per token is the regression"
            )
        }

        // And it still rendered: a path that stopped presenting would score zero
        // on both counters above.
        guard transcript.qaSemanticRowCount > history else {
            throw fail(
                "streaming locality: the streamed answer never became a row — "
                + "\(transcript.qaSemanticRowCount) rows for \(history) of history"
            )
        }
    }

    @MainActor
    private static func checkStreamingResponseKeepsALivenessSignal() throws {
        let thread = "thread-main"
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: UUID(),
            kind: .managedAgent,
            title: "streaming-liveness",
            frame: TileFrame(x: 0, y: 0, width: 560, height: 460),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        ))
        tile.layoutSubtreeIfNeeded()

        // Real events through the real reducer — not a hand-built document.
        tile.ingest(.turnStarted(threadId: thread, turnId: "turn-1"))
        tile.ingest(.contentDelta(
            threadId: thread, turnId: "turn-1", streamKind: .assistant,
            delta: "Here is the first half of an answer"))

        // The fixture's own teeth. If an open assistant entry stops being what a
        // mid-stream document ends with, this witness would pass vacuously while
        // saying nothing — so prove the state under test actually exists first.
        let document = tile.qaDocumentForChecks
        guard let last = document.entries.last else {
            throw fail("streaming liveness: ingesting a delta produced no entry at all")
        }
        guard last.role == .assistant else {
            throw fail(
                "streaming liveness: a mid-stream document ended with a \(last.role) entry, so "
                + "this check no longer exercises the state it was written for"
            )
        }
        guard case .open = last.lifecycle else {
            throw fail(
                "streaming liveness: the streaming entry was already \(last.lifecycle), so the "
                + "suppression this guards could not have applied — fixture is toothless"
            )
        }

        // THE assertion: mid-answer, with work genuinely in flight, the tail stays.
        guard ManagedAgentTileNSView.showsWorkingTail(
            statusIsActive: true, document: document, turnLiveness: tile.turnLiveness) else {
            throw fail(
                "streaming liveness: the tail was suppressed while an assistant entry was "
                + "streaming — the gyro is the only animated element in the transcript and the "
                + "compact row is silent for live phases, so the turn looks dead exactly while "
                + "the model is answering"
            )
        }

        // And the tail is not simply always on: a settled turn must still yield.
        guard !ManagedAgentTileNSView.showsWorkingTail(
            statusIsActive: false, document: document, turnLiveness: tile.turnLiveness) else {
            throw fail(
                "streaming liveness: the tail stayed up with no work in flight — a liveness "
                + "signal that is always on carries no information"
            )
        }

        // Mid-answer the tile must actually believe a turn is running. Teeth for
        // the assertion below: if the boundary never reached `.inFlight`, the
        // "completed hides it" assertion would pass for the wrong reason.
        guard tile.turnLiveness == .inFlight else {
            throw fail(
                "streaming liveness: mid-answer the tile's turn boundary was \(tile.turnLiveness), "
                + "so it never saw the turn start"
            )
        }

        // THE regression this pair exists for. Dylan, watching a live tile:
        // "the agent is done but i still see it."
        //
        // `statusIsActive` is deliberately passed as TRUE here, because that is
        // precisely the situation: `descriptor.status` is republished
        // asynchronously and still says `.working` when the turn's own completion
        // event has already arrived — and on a runner that stalls it says so
        // forever. The tail used to be saved from this by accident, because its
        // old predicate also required the last entry not to be an open stream.
        // Removing that term to keep the gyro up during streaming removed the
        // accident too, and turned "silently hidden on a stall" into "spins
        // forever on a stall".
        tile.ingest(.turnCompleted(
            threadId: thread, turnId: "turn-1", outcome: .completed, errorMessage: nil))
        guard tile.turnLiveness == .completed else {
            throw fail(
                "streaming liveness: a turnCompleted event left the tile's turn boundary at "
                + "\(tile.turnLiveness) — the tail's authority never learned the turn ended"
            )
        }
        guard !ManagedAgentTileNSView.showsWorkingTail(
            statusIsActive: true, document: tile.qaDocumentForChecks,
            turnLiveness: tile.turnLiveness) else {
            throw fail(
                "streaming liveness: the tail stayed up after the turn's own completion event, "
                + "on the strength of a status that had not caught up yet — an agent that is "
                + "done must not keep spinning"
            )
        }

        // The other exit, for a runner that dies without ever sending
        // turnCompleted: a stopped session ends the turn too.
        let stopped = ManagedAgentTileNSView(tile: Tile(
            id: UUID(), kind: .managedAgent, title: "streaming-liveness-stopped",
            frame: TileFrame(x: 0, y: 0, width: 560, height: 460),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        stopped.layoutSubtreeIfNeeded()
        stopped.ingest(.turnStarted(threadId: thread, turnId: "turn-1"))
        stopped.ingest(.contentDelta(
            threadId: thread, turnId: "turn-1", streamKind: .assistant, delta: "half an answer"))
        stopped.ingest(.sessionStateChanged(.stopped))
        guard !ManagedAgentTileNSView.showsWorkingTail(
            statusIsActive: true, document: stopped.qaDocumentForChecks,
            turnLiveness: stopped.turnLiveness) else {
            throw fail(
                "streaming liveness: the tail stayed up after the session stopped mid-turn — a "
                + "runner that dies never sends turnCompleted, so this is the exit that has to work"
            )
        }

        // A reduce-motion reader gets the same INFORMATION. The gyro falls back
        // to a fixed pose rather than disappearing, so the signal must not be
        // conditioned on motion being available.
        AgentTranscriptMotion.qaWithMotion(enabled: true, reducedMotion: true) {
            tile.qaTranscriptForChecks?.setThinkingIndicatorVisible(true)
        }
        guard tile.qaThinkingIndicatorVisible else {
            throw fail(
                "streaming liveness: the tail vanished under reduce-motion — the fixed-pose "
                + "fallback exists so the signal survives without the animation"
            )
        }
    }

}
