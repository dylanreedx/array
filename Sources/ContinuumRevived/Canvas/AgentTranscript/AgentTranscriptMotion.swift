import AppKit

/// The transcript's whole motion vocabulary, in one place.
///
/// Dylan's brief: "Codex is so smooth and chill, most things have a subtle
/// animation" — the transcript snapped between states instead. The stability
/// pass before this one removed the *causes* of jumping (rows deleted under the
/// reader, geometry churn); this adds the softening on top.
///
/// Two rules make it safe against every gate the transcript is held to, and
/// neither is negotiable:
///
/// 1. **Presentation only.** Every animation here is a `CABasicAnimation` whose
///    `toValue` is the value the model ALREADY holds — nothing mutates
///    `alphaValue`, a frame, or a constraint. A synchronous read immediately
///    after the call therefore returns the settled value, so
///    `--ui-geometry-check`, the appearance census and the delta oracle see
///    exactly what they saw before. Nothing here touches the diffable snapshot,
///    so `animatingDifferences` stays `false` and `qaVisualApplyCount == 1`
///    holds.
/// 2. **Off unless an owner turns it on.** `isEnabled` defaults to `false` and
///    production sets it once, in the interactive launch path only. Every
///    `--*-check` leg — pixel baselines, the tour renders, the appearance sweep
///    — runs before that line and so photographs a motionless transcript. A
///    frame captured mid-fade would be a flapping baseline, and the house rule
///    is that a flapping fixture is a bug, never a tolerance to widen.
@MainActor
enum AgentTranscriptMotion {
    /// New content arriving in the transcript.
    static let arrival: TimeInterval = 0.18
    /// A revealed pane, a re-driven line — something already on screen changing.
    static let emphasis: TimeInterval = 0.16

    /// Production's single opt-in. Left `false` for every check and fixture
    /// surface; injected so a witness can drive the animated path deliberately.
    static var isEnabled: () -> Bool = { false }

    /// Injected rather than read at each call site so a witness can drive the
    /// reduced path without touching the user's real accessibility settings.
    static var prefersReducedMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var shouldAnimate: Bool { isEnabled() && !prefersReducedMotion() }

    /// Fades a view up to the opacity it already has. Used for content the
    /// reader has not seen before: a row arriving, a pane a disclosure just
    /// revealed, a cluster header replacing the run it folded.
    static func fadeIn(_ view: NSView, duration: TimeInterval = arrival, from: Float = 0) {
        animateOpacity(view, from: from, duration: duration)
    }

    /// A softer version for something already on screen whose value changed —
    /// a tool row resolving from "In progress" to "2.1s ✓". It reads as the
    /// text settling rather than being swapped.
    static func settle(_ view: NSView) {
        animateOpacity(view, from: 0.25, duration: emphasis)
    }

    private static func animateOpacity(_ view: NSView, from: Float, duration: TimeInterval) {
        guard shouldAnimate else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        // The model value, untouched — see rule 1. A gate reading opacity after
        // this call reads the settled number.
        animation.toValue = layer.opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "agent.transcript.opacity")
    }

    // MARK: - QA seams

    /// Runs `body` with motion forced to a known state, restoring both closures
    /// afterwards. Witnesses use this instead of writing the statics directly,
    /// so a failing assertion cannot leak an enabled flag into a later leg.
    static func qaWithMotion(enabled: Bool, reducedMotion: Bool = false, _ body: () -> Void) {
        let previousEnabled = isEnabled
        let previousReduced = prefersReducedMotion
        isEnabled = { enabled }
        prefersReducedMotion = { reducedMotion }
        body()
        isEnabled = previousEnabled
        prefersReducedMotion = previousReduced
    }

    /// The presentation animation a view is currently running, if any — the
    /// only way a witness can tell "faded in" from "appeared".
    static func qaRunningOpacityAnimation(_ view: NSView) -> CABasicAnimation? {
        view.layer?.animation(forKey: "agent.transcript.opacity") as? CABasicAnimation
    }
}
