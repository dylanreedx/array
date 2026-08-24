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
        private let acceptance: IntentAcceptance
        private let hold: (@MainActor () async -> Void)?

        init(_ acceptance: IntentAcceptance, hold: (@MainActor () async -> Void)? = nil) {
            self.acceptance = acceptance
            self.hold = hold
        }

        func note(_ event: String) { events.append(event) }

        func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance {
            acceptEntered = true
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
        print("ContinuumRevivedAgentFirstPaintChecks passed: the prompt echo precedes the action sink, acceptance and refusal both resolve the latch, the spawn window carries a state, a word, and a clock, the optimistic indicator survives synchronize, and settled turns read their duration")
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
