import AppKit
import ContinuumRevivedCore

/// The single owner of camera INPUT — one gesture pipeline for pan and zoom.
///
/// Before this existed, three handlers wrote the viewport independently: the
/// scroll monitor (pan and Cmd+zoom), the magnify monitor (pinch), and a
/// 120 Hz `Timer` prototype for pinch momentum. Each applied synchronously per
/// event, none knew the others existed, and the seams between them were where
/// the canvas felt wrong: a momentum glide kept zooming around a frozen anchor
/// while a following pan divided its deltas by a zoom that changed underneath
/// it — content that does not stay under the fingers, which a hand reads as
/// lag at any frame rate.
///
/// The design is the one .plans/22 Slice 2 specified and nobody built:
/// accumulate input continuously, submit at most the newest desired camera
/// state per display interval, never replay obsolete intermediate viewports,
/// never run a fixed tick. Concretely:
///
/// - Inputs ACCUMULATE (pan deltas add, zoom deltas add in LOG space — zoom is
///   multiplicative, so 1→2 and 2→4 are the same gesture).
/// - The first input of a display interval applies IMMEDIATELY, so sparse
///   input (the normal case — events arrive about once per frame) keeps
///   exactly today's latency and pan stays untouched. Only a backlog — more
///   events than frames — coalesces, which is precisely the case where
///   replaying each intermediate viewport was pure waste.
/// - Pinch momentum lives here, display-linked (`NSView.displayLink`), decay
///   scaled by real frame dt. A glide COMPOSES with pan input in the same
///   commit around a live anchor instead of fighting it, stops at the zoom
///   clamp instead of ticking a pinned camera, and dies the moment a new
///   pinch, a pointer drag, or a programmatic navigation takes the camera.
/// - Both zoom inputs run through one curve: a log-zoom delta with one gain
///   per device (`log(1 + magnification)` for pinch, `deltaY × gain` for
///   Cmd+scroll — `exp(x) ≈ 1+x`, the historical disagreement was gain, not
///   shape).
///
/// The driver never mutates the camera directly: it composes ONE new viewport
/// and hands it to `CanvasNSView.setViewport`, which stays synchronous and
/// remains the single truth every oracle and scenario asserts against.
@MainActor
final class CanvasCameraDriver: NSObject {

    /// Shipped values, overridable from the environment for hand-tuning
    /// sessions only. The env keys are tuning scaffolding, not configuration —
    /// once a value is signed off it becomes the default here.
    struct Tuning {
        /// Log-zoom per unit of Cmd+scroll `scrollingDeltaY` (~±10%/logical line).
        var scrollZoomGain: Double = 0.02
        /// Multiplier on the pinch's own `log(1 + magnification)`.
        var pinchZoomGain: Double = 1.0
        /// Log-zoom velocity (1/s) below which a pinch release is a deliberate
        /// stop, not a flick — glide would fight the user, so none starts.
        var glideEngageThreshold: Double = 0.35
        /// Glide velocity half-life. 55 ms reproduces the prototype's ×0.90
        /// per 1/120 s that Dylan already rated an improvement.
        var glideHalfLife: TimeInterval = 0.055
        /// Velocity floor at which a glide is over.
        var glideFloor: Double = 0.02
        /// After a zoom input, precise-scroll keeps steering the CAMERA for this
        /// long even over tile content, so a pinch→pan handoff over a terminal
        /// does not hand the follow-through to the tile and stop the canvas dead.
        var stickiness: TimeInterval = 0.30
        /// Camera quiet time that counts as settled.
        var settleQuiet: TimeInterval = 0.25
        /// The leading-edge window: an input applies immediately unless a
        /// commit already happened within this interval. 1/120 s is one frame
        /// on the fastest supported panel — on slower panels it allows a
        /// harmless extra commit rather than adding latency.
        var minCommitInterval: TimeInterval = 1.0 / 120.0

        static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Tuning {
            var tuning = Tuning()
            func read(_ key: String, _ apply: (Double) -> Void) {
                if let raw = env[key], let value = Double(raw), value.isFinite, value > 0 { apply(value) }
            }
            read("ARRAY_SCROLL_ZOOM_GAIN") { tuning.scrollZoomGain = $0 }
            read("ARRAY_PINCH_ZOOM_GAIN") { tuning.pinchZoomGain = $0 }
            read("ARRAY_ZOOM_GLIDE_ENGAGE") { tuning.glideEngageThreshold = $0 }
            read("ARRAY_ZOOM_GLIDE_HALFLIFE_MS") { tuning.glideHalfLife = $0 / 1_000 }
            read("ARRAY_ZOOM_GLIDE_FLOOR") { tuning.glideFloor = $0 }
            read("ARRAY_CAMERA_STICKINESS_MS") { tuning.stickiness = $0 / 1_000 }
            return tuning
        }
    }

    let tuning: Tuning
    private let currentViewport: () -> CanvasViewport
    private let applyViewport: (CanvasViewport) -> Void
    private let makeDisplayLink: (CanvasCameraDriver, Selector) -> CADisplayLink?

    /// True while the driver itself is inside `applyViewport`, so the canvas
    /// can tell a driver commit from an external write (navigation snap,
    /// restore, self-check) — external writes cancel in-flight gestures.
    private(set) var isApplying = false

    /// Injectable clock so checks are deterministic. Wall time in production.
    var nowProvider: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    // Accumulated input, cleared on every commit.
    private var pendingPanDX: CGFloat = 0
    private var pendingPanDY: CGFloat = 0
    private var pendingLogZoom: Double = 0
    /// The last pointer position any camera input reported, in canvas
    /// coordinates. LIVE on purpose: a glide that zooms around a frozen
    /// finger-lift point while the user pans slides the content out from under
    /// them. Read-only outside: sharpness promotion orders its per-step budget
    /// nearest-anchor-first, so the tile the user is zooming toward sharpens
    /// before the periphery.
    private(set) var anchor: CGPoint = .zero

    // Pinch velocity tracking (log space).
    private var pinchActive = false
    private var lastPinchTimestamp: TimeInterval?
    private var pinchLogVelocity: Double = 0

    // Glide state.
    private(set) var glideActive = false
    private var glideVelocity: Double = 0
    private var lastGlideTimestamp: TimeInterval?

    // Pacing, settle, session.
    private var lastCommitTime: TimeInterval = -.infinity
    private var lastActivityTime: TimeInterval = -.infinity
    private var lastZoomInputTime: TimeInterval = -.infinity
    private var settled = true
    private var displayLink: CADisplayLink?
    private var backstopTimer: Timer?

    /// Fired once per activity burst, `settleQuiet` after the camera goes
    /// still. Deferred consumers (persistence, hydration reconcile, cursor
    /// rects) hang off this instead of re-arming their own timers per step.
    var onSettle: (() -> Void)?

    init(
        tuning: Tuning,
        currentViewport: @escaping () -> CanvasViewport,
        applyViewport: @escaping (CanvasViewport) -> Void,
        makeDisplayLink: @escaping (CanvasCameraDriver, Selector) -> CADisplayLink?
    ) {
        self.tuning = tuning
        self.currentViewport = currentViewport
        self.applyViewport = applyViewport
        self.makeDisplayLink = makeDisplayLink
    }

    // MARK: - Input taps

    func noteScrollPan(dx: CGFloat, dy: CGFloat, location: CGPoint) {
        pendingPanDX += dx
        pendingPanDY += dy
        anchor = location
        noteActivity(zoom: false)
        submit()
    }

    func noteScrollZoom(deltaY: Double, location: CGPoint) {
        pendingLogZoom += deltaY * tuning.scrollZoomGain
        anchor = location
        noteActivity(zoom: true)
        submit()
    }

    func notePinch(magnification: Double, phase: NSEvent.Phase, location: CGPoint, timestamp: TimeInterval) {
        switch phase {
        case .began:
            cancelGlide()
            pinchActive = true
            pinchLogVelocity = 0
            lastPinchTimestamp = timestamp
            anchor = location
            noteActivity(zoom: true)
        case .ended, .cancelled:
            pinchActive = false
            lastPinchTimestamp = nil
            noteActivity(zoom: true)
            maybeStartGlide()
        default:
            let factor = 1.0 + magnification
            guard factor > 0 else { return }
            let logDelta = log(factor) * tuning.pinchZoomGain
            pendingLogZoom += logDelta
            anchor = location
            if let last = lastPinchTimestamp, timestamp > last {
                // dt is clamped so a delivery stall cannot read as a slow finger,
                // and the velocity is smoothed so one jittery final event does
                // not decide the whole glide.
                let dt = min(timestamp - last, 0.05)
                pinchLogVelocity = pinchLogVelocity * 0.6 + (logDelta / dt) * 0.4
            }
            lastPinchTimestamp = timestamp
            noteActivity(zoom: true)
            submit()
        }
    }

    /// Called by the canvas when anything OTHER than this driver writes the
    /// viewport — a navigation snap, a restore, a pointer-pan drag, a check.
    /// That writer owns the camera now: gestures in flight must not keep
    /// steering it. Field writes only — this sits on the perf scenarios' hot
    /// path, where every `setViewport` call lands here.
    func noteExternalViewportChange() {
        if glideActive { cancelGlide() }
        pendingPanDX = 0
        pendingPanDY = 0
        pendingLogZoom = 0
        pinchActive = false
    }

    /// Is the user mid-camera-gesture (or just barely out of one)? The scroll
    /// monitor consults this to keep a pinch→pan handoff steering the camera
    /// instead of handing the follow-through to tile content. Sticky only
    /// after ZOOM input — a plain pan over a tile must still scroll the tile.
    var isCameraSessionActive: Bool {
        if pinchActive || glideActive { return true }
        return nowProvider() - lastZoomInputTime < tuning.stickiness
    }

    // MARK: - Commit pacing

    private func submit() {
        let now = nowProvider()
        if now - lastCommitTime >= tuning.minCommitInterval {
            applyPending(at: now)
        } else {
            // A commit already landed this interval: the newest state waits for
            // the next display callback instead of replaying intermediates.
            ensureDisplayLink()
        }
    }

    private func applyPending(at now: TimeInterval) {
        guard pendingPanDX != 0 || pendingPanDY != 0 || pendingLogZoom != 0 else { return }
        var viewport = currentViewport()
        let zoomBefore = viewport.zoom
        if pendingPanDX != 0 || pendingPanDY != 0 {
            viewport.x -= Double(pendingPanDX) / viewport.zoom
            viewport.y -= Double(pendingPanDY) / viewport.zoom
        }
        var zoomRequested = false
        if pendingLogZoom != 0 {
            let factor = exp(pendingLogZoom)
            if factor.isFinite, factor > 0 {
                viewport = CanvasEngine.zoom(viewport, by: factor, anchorScreen: anchor)
                zoomRequested = true
            }
        }
        pendingPanDX = 0
        pendingPanDY = 0
        pendingLogZoom = 0
        isApplying = true
        applyViewport(viewport)
        isApplying = false
        lastCommitTime = now
        // At the zoom clamp the glide has nothing left to push against: stop it
        // rather than tick a pinned camera until the velocity floor.
        if glideActive, zoomRequested, abs(currentViewport().zoom - zoomBefore) < 1e-9 {
            cancelGlide()
        }
    }

    // MARK: - Glide

    private func maybeStartGlide() {
        guard abs(pinchLogVelocity) > tuning.glideEngageThreshold else { return }
        glideVelocity = pinchLogVelocity
        glideActive = true
        lastGlideTimestamp = nil
        ensureDisplayLink()
    }

    func cancelGlide() {
        glideActive = false
        glideVelocity = 0
        lastGlideTimestamp = nil
    }

    private func stepGlide(dt: TimeInterval) {
        guard glideActive, dt > 0 else { return }
        glideVelocity *= pow(0.5, dt / tuning.glideHalfLife)
        guard abs(glideVelocity) >= tuning.glideFloor, glideVelocity.isFinite else {
            cancelGlide()
            return
        }
        pendingLogZoom += glideVelocity * dt
    }

    // MARK: - Display link + settle

    private func noteActivity(zoom: Bool) {
        let now = nowProvider()
        lastActivityTime = now
        if zoom { lastZoomInputTime = now }
        settled = false
        ensureDisplayLink()
    }

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        guard let link = makeDisplayLink(self, #selector(tick(_:))) else {
            // No window yet — the backstop alone still flushes and settles.
            armBackstop()
            return
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        armBackstop()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = nowProvider()
        if glideActive {
            let dt: TimeInterval
            if let last = lastGlideTimestamp {
                dt = min(max(link.timestamp - last, 0), 0.05)
            } else {
                dt = max(link.targetTimestamp - link.timestamp, 0)
            }
            lastGlideTimestamp = link.timestamp
            stepGlide(dt: dt)
            lastActivityTime = now
        }
        applyPending(at: now)
        if !glideActive, now - lastActivityTime >= tuning.settleQuiet {
            stopDisplayLink()
            markSettled()
        }
    }

    /// The display link stops ticking when the window is occluded or the app
    /// deactivates (CanvasFrameRecorder learned this the hard way): pending
    /// input and the settle signal must not strand with it.
    private func armBackstop() {
        backstopTimer?.invalidate()
        let timer = Timer(timeInterval: tuning.settleQuiet * 2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.backstopFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        backstopTimer = timer
    }

    private func backstopFired() {
        backstopTimer = nil
        let now = nowProvider()
        if glideActive, displayLink != nil, now - lastActivityTime < tuning.settleQuiet {
            // The link is alive and ticking (it refreshed lastActivityTime);
            // this was just the periodic re-arm.
            armBackstop()
            return
        }
        // Link stalled or gone: finish what is in flight rather than freeze it.
        cancelGlide()
        applyPending(at: now)
        if now - lastActivityTime >= tuning.settleQuiet {
            stopDisplayLink()
            markSettled()
        } else {
            armBackstop()
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        backstopTimer?.invalidate()
        backstopTimer = nil
    }

    /// Whether the camera is at rest. Read by the residency policy, which allows
    /// promotions during motion but never bulk demotions — a demote sweep mid-
    /// gesture is exactly what slice 1's transition cost was.
    var isSettled: Bool { settled }

    private func markSettled() {
        guard !settled else { return }
        settled = true
        onSettle?()
    }

    // MARK: - QA seams (deterministic time — no runloop, no wall clock)

    /// Apply whatever is accumulated right now, as the next display tick would.
    func qaFlushPending() {
        applyPending(at: nowProvider())
    }

    /// Advance the glide by `dt` and commit, exactly as one link tick would.
    func qaStepGlide(dt: TimeInterval) {
        stepGlide(dt: dt)
        applyPending(at: nowProvider())
    }

    var qaGlideActive: Bool { glideActive }
    var qaPinchLogVelocity: Double { pinchLogVelocity }
    var qaHasPendingInput: Bool { pendingPanDX != 0 || pendingPanDY != 0 || pendingLogZoom != 0 }
    func qaMarkSettledNow() {
        cancelGlide()
        qaFlushPending()
        markSettled()
    }
}
