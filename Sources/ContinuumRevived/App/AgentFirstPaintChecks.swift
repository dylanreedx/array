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
        print("ContinuumRevivedAgentFirstPaintChecks passed: the prompt echo precedes the action sink, acceptance and refusal both resolve the latch, the spawn window carries a state, a word, and a clock, the optimistic indicator survives synchronize, settled turns read their duration, a mid-turn attachment resolves honestly instead of forcing sendPrompt, and a popover-selected command echoes exactly like a typed one")
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
