import ContinuumRevivedCore
import Foundation

/// DI-01 prototype gate. Every assertion below drives the REAL
/// `DictationSession` through the `DictationEngine` seam with a fake engine —
/// no microphone, no `Speech` framework, no display, no clock. The behaviours
/// asserted are the ones that make dictation safe to put in a composer:
/// cancel leaves no trace, volatile text never reaches persistence, a late
/// engine event cannot resurrect a dead session, and two tiles cannot both hold
/// the microphone.

/// Records everything a host would observe, so an assertion can name COUNTS and
/// not merely final values. Counting is the point: the failure this gate exists
/// to prevent is a correct-looking final string produced by hundreds of writes.
@MainActor
private final class DictationObserver {
    var states: [DictationState] = []
    var provisionals: [String] = []
    var commits: [String] = []
    var levels: [Float] = []
    var outcomes: [DictationOutcome] = []

    init(_ session: DictationSession) {
        session.onSessionEnd = { [weak self] in self?.outcomes.append($0) }
        session.onStateChange = { [weak self] in self?.states.append($0) }
        session.onProvisionalChange = { [weak self] in self?.provisionals.append($0) }
        session.onCommit = { [weak self] in self?.commits.append($0) }
        session.onLevel = { [weak self] in self?.levels.append($0) }
    }
}

/// `DictationSession.start()` drives `prepare()` inside a Task, so the engine's
/// `.ready` lands on a later turn of the main actor. Checks await this rather
/// than sleeping, so they stay deterministic and take no wall-clock time.
@MainActor
private func settleDictationActor() async {
    for _ in 0..<4 { await Task.yield() }
}

@MainActor
private func makeListeningSession() async -> (DictationSession, FakeDictationEngine, DictationObserver) {
    let engine = FakeDictationEngine()
    let session = DictationSession(engine: engine)
    let observer = DictationObserver(session)
    session.start()
    await settleDictationActor()
    return (session, engine, observer)
}

@MainActor
func runDictationSessionChecks() async throws {
    var assertions = 0
    func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        expect(condition(), message)
        assertions += 1
    }

    // W1 — the transition table, including every refused edge.
    do {
        let (session, engine, _) = await makeListeningSession()
        require(session.state == .listening, "dictation W1: prepare/ready did not reach listening")
        require(engine.isCapturing, "dictation W1: listening without a live capture")
        require(session.start() == false, "dictation W1: a second start was accepted while listening")
        require(session.stop(), "dictation W1: stop refused from listening")
        require(session.state == .idle, "dictation W1: finished did not land in idle")
        require(session.stop() == false, "dictation W1: stop accepted from idle")
        require(session.cancel() == false, "dictation W1: cancel accepted from idle")
        require(engine.isCapturing == false, "dictation W1: capture outlived the session")
    }

    // W2 — cancel from each active state leaves NOTHING behind.
    for stage in ["preparing", "listening", "finalizing"] {
        let engine = FakeDictationEngine()
        if stage == "preparing" { engine.prepareOutcome = .hangs }
        if stage == "finalizing" { engine.emitsFinishedOnStop = false }
        let session = DictationSession(engine: engine)
        let observer = DictationObserver(session)
        session.start()
        await settleDictationActor()

        if stage != "preparing" {
            // A settled segment FIRST. Without this the committed-text
            // assertions below are vacuous — which is exactly how an earlier
            // revision of this gate stayed green while `cancel()` was broken.
            engine.emitFinal("settled words")
            engine.emitVolatile("delete this hypothesis")
            if stage == "finalizing" { session.stop() }
        }

        let expectedState: DictationState = stage == "preparing"
            ? .preparing
            : (stage == "finalizing" ? .finalizing : .listening)
        require(session.state == expectedState, "dictation W2/\(stage): wrong pre-cancel state")

        require(session.cancel(), "dictation W2/\(stage): cancel refused")
        require(session.state == .idle, "dictation W2/\(stage): cancel did not reach idle")
        require(session.provisionalText.isEmpty, "dictation W2/\(stage): provisional text survived cancel")
        require(session.committedText.isEmpty, "dictation W2/\(stage): SETTLED text survived cancel")
        require(engine.isCapturing == false, "dictation W2/\(stage): microphone still hot after cancel")
        // The host learns to withdraw its whole inserted range from HERE, which
        // is the only signal that keeps host and session agreeing about what
        // survived a cancel.
        require(
            observer.outcomes == [.cancelled],
            "dictation W2/\(stage): expected exactly one .cancelled outcome, saw \(observer.outcomes)"
        )

        // A late buffer from the abandoned engine must be inert.
        engine.emit(.volatile("late"))
        engine.emit(.final("late"))
        require(session.state == .idle, "dictation W2/\(stage): a late event revived a cancelled session")
        require(session.committedText.isEmpty, "dictation W2/\(stage): a late event committed text")
        require(observer.outcomes == [.cancelled], "dictation W2/\(stage): a late event produced a second outcome")
    }

    // W3 — five volatile results then one final produce exactly ONE commit.
    // This is the persistence gate: the composer writes its draft store on every
    // published change, so a volatile result reaching that path is one disk
    // write per partial.
    do {
        let (session, engine, observer) = await makeListeningSession()
        for hypothesis in ["re", "ref", "refac", "refactor", "refactor the"] {
            engine.emitVolatile(hypothesis)
        }
        require(observer.commits.isEmpty, "dictation W3: a volatile result was committed")
        require(session.provisionalText == "refactor the", "dictation W3: provisional text did not track the last hypothesis")
        engine.emitFinal("refactor the composer")
        require(observer.commits.count == 1, "dictation W3: expected exactly 1 commit, saw \(observer.commits.count)")
        require(session.committedText == "refactor the composer", "dictation W3: committed text wrong")
        require(session.provisionalText.isEmpty, "dictation W3: provisional span survived finalization")
        require(session.hasProvisionalText == false, "dictation W3: hasProvisionalText true with no hypothesis")
    }

    // W6 — typing during dictation settles the hypothesis and re-anchors, so a
    // later volatile result cannot reach back across what the user wrote.
    do {
        let (session, engine, observer) = await makeListeningSession()
        engine.emitVolatile("open the file")
        session.userDidEdit()
        require(observer.commits == ["open the file"], "dictation W6: user edit did not settle the hypothesis")
        require(session.provisionalText.isEmpty, "dictation W6: provisional span survived a user edit")
        engine.emitVolatile("and run it")
        require(session.provisionalText == "and run it", "dictation W6: the re-anchored span did not accept new text")
        require(session.committedText == "open the file", "dictation W6: a later hypothesis rewrote settled text")
    }

    // W7 — one capture owner across tiles.
    do {
        let engineA = FakeDictationEngine()
        let sessionA = DictationSession(engine: engineA)
        let engineB = FakeDictationEngine()
        let sessionB = DictationSession(engine: engineB)
        let coordinator = DictationCoordinator()

        coordinator.adopt(sessionA)
        sessionA.start()
        await settleDictationActor()
        require(sessionA.state == .listening, "dictation W7: tile A never reached listening")

        coordinator.adopt(sessionB)
        sessionB.start()
        await settleDictationActor()
        require(sessionA.state == .idle, "dictation W7: tile A kept its session when tile B started")
        require(engineA.isCapturing == false, "dictation W7: TWO live microphone taps")
        require(sessionB.state == .listening, "dictation W7: tile B never reached listening")
    }

    // W8 — the composer's rebind/close path discards without persisting.
    do {
        let (session, engine, observer) = await makeListeningSession()
        let coordinator = DictationCoordinator()
        coordinator.adopt(session)
        engine.emitVolatile("half a sentence")
        coordinator.relinquish(session)
        require(session.state == .idle, "dictation W8: relinquish did not stop the session")
        require(observer.commits.isEmpty, "dictation W8: tile close persisted a hypothesis")
        require(engine.isCapturing == false, "dictation W8: tile close left the microphone hot")
    }

    // W10 — a failure is a category, never engine prose, and keeps SETTLED text
    // while discarding the hypothesis.
    do {
        let (session, engine, observer) = await makeListeningSession()
        engine.emitFinal("keep me")
        engine.emitVolatile("drop me")
        engine.emitFailure(.audioEngineFailed)
        require(session.state == .error(.audioEngineFailed), "dictation W10: failure did not reach the error state")
        require(session.provisionalText.isEmpty, "dictation W10: hypothesis survived a failure")
        require(session.committedText == "keep me", "dictation W10: a failure discarded settled text")
        require(observer.commits == ["keep me"], "dictation W10: wrong commit set after failure")
        require(engine.isCapturing == false, "dictation W10: failure left the microphone hot")
        // Recovery: error is a legal start state, unlike the active ones.
        require(session.start(), "dictation W10: could not restart from error")
    }

    // Permission denial arrives from `prepare()`, not from the event stream.
    do {
        let engine = FakeDictationEngine()
        engine.prepareOutcome = .fails(.microphonePermissionDenied)
        let session = DictationSession(engine: engine)
        session.start()
        await settleDictationActor()
        require(
            session.state == .error(.microphonePermissionDenied),
            "dictation: a denied microphone did not surface as an error state"
        )
        require(engine.startCallCount == 0, "dictation: capture started despite a denied permission")
    }

    print("DictationSessionChecks: \(assertions) state-machine assertions over the fake engine")
}

/// Deliberately demands a forbidden result from the compiled state machine.
/// Registered as a negative control: if this does NOT fail, the gate above has
/// no teeth and every assertion in it is decorative.
@MainActor
func runDictationSessionNegativeWitness() async {
    let engine = FakeDictationEngine()
    let session = DictationSession(engine: engine)
    var commits = 0
    session.onCommit = { _ in commits += 1 }
    session.start()
    await settleDictationActor()
    for hypothesis in ["a", "ab", "abc"] { engine.emitVolatile(hypothesis) }
    expect(
        commits == 3,
        "dictation negative witness: volatile results were committed one-for-one"
    )
}

@MainActor
func runDictationLevelMeterChecks() throws {
    var assertions = 0
    func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        expect(condition(), message)
        assertions += 1
    }

    // Perceptual mapping: silence floors, full scale tops out, and ordinary
    // speech must land in the visible upper half rather than as a stub.
    require(DictationLevelMeter.normalized(rms: 0) == 0, "level meter: silence is not zero")
    require(DictationLevelMeter.normalized(rms: 1) == 1, "level meter: full scale is not one")
    require(
        DictationLevelMeter.normalized(rms: 0.0001) == 0,
        "level meter: room tone below the floor still registered"
    )
    let speech = DictationLevelMeter.normalized(rms: 0.2)
    require(speech > 0.5, "level meter: ordinary speech (rms 0.2) mapped to \(speech), which would barely move a bar")
    require(
        DictationLevelMeter.normalized(rms: 0.2) > DictationLevelMeter.normalized(rms: 0.05),
        "level meter: mapping is not monotonic"
    )

    // Envelope: attack is fast, release is slow. This asymmetry is what stops
    // the bars flickering on ordinary speech.
    var meter = DictationLevelMeter()
    let buffer: Float = 0.01
    for _ in 0..<5 { meter.record(rms: 0.5, deltaTime: buffer) }
    let attacked = meter.envelope
    require(attacked > 0.5, "level meter: attack too slow — envelope only reached \(attacked)")
    for _ in 0..<5 { meter.record(rms: 0, deltaTime: buffer) }
    require(meter.envelope > 0.1, "level meter: release too fast — bars will flicker between syllables")

    // Resting floor: a listening meter is never completely flat.
    var quiet = DictationLevelMeter()
    for _ in 0..<200 { quiet.record(rms: 0, deltaTime: buffer) }
    quiet.advanceBar()
    require(
        quiet.displayBars.allSatisfy { $0 >= DictationLevelMeter.restingLevel },
        "level meter: silence rendered flat, which reads as broken rather than listening"
    )

    // History scrolls and preserves length.
    var scrolling = DictationLevelMeter(barCount: 4)
    for _ in 0..<4 { scrolling.advanceBar() }
    for _ in 0..<20 { scrolling.record(rms: 0.9, deltaTime: buffer) }
    scrolling.advanceBar()
    require(scrolling.bars.count == 4, "level meter: bar count drifted to \(scrolling.bars.count)")
    require(scrolling.bars.last! > scrolling.bars.first!, "level meter: newest bar is not at the end")

    // Decay settles rather than cutting; reset is immediate and total.
    var decaying = DictationLevelMeter()
    for _ in 0..<20 { decaying.record(rms: 0.9, deltaTime: buffer) }
    decaying.advanceBar()
    require(decaying.isSilent == false, "level meter: a loud meter reported silent")
    for _ in 0..<200 { decaying.decay(deltaTime: buffer) }
    require(decaying.isSilent, "level meter: decay never settled, so the waveform would never collapse")

    var resetting = DictationLevelMeter()
    for _ in 0..<20 { resetting.record(rms: 0.9, deltaTime: buffer) }
    resetting.advanceBar()
    resetting.reset()
    require(resetting.isSilent, "level meter: reset left residue, so cancel would flash old audio")

    print("DictationLevelMeterChecks: \(assertions) waveform arithmetic assertions")
}
