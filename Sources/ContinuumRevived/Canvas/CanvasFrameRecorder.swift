import AppKit
import ContinuumRevivedCore

/// Live frame-time instrumentation for canvas gestures.
///
/// Before this existed, nothing in the app measured frame time, so "is the
/// canvas at 60?" could not be answered by anyone — the only evidence available
/// was the user saying it felt laggy. Offline budgets (`PerfBudget`) prove the
/// canvas does not do wasteful WORK; this proves what the display actually did
/// on the user's machine, with their tiles, at their refresh rate.
///
/// It is inert unless frame logging or the opt-in frame HUD is enabled, because
/// anything that can present or log at boot must stay quiet in QA runs and in
/// front of users.
///
/// A gesture is bracketed by camera activity rather than by AppKit gesture
/// phases: every pan increment and zoom increment funnels through
/// `CanvasNSView.setViewport`, and a gesture is "over" when that goes quiet for
/// `settleSeconds`. That covers the trackpad scroll branch, the pinch branch and
/// the pointer-pan drag identically.
@MainActor
final class CanvasFrameRecorder {
    static var isLoggingEnabled: Bool {
        ProcessInfo.processInfo.environment["CONTINUUM_FRAME_STATS"] == "1"
    }

    static var isHUDEnabled: Bool {
        ProcessInfo.processInfo.environment["CONTINUUM_FRAME_HUD"] == "1"
    }

    static var isEnabled: Bool {
        isLoggingEnabled || isHUDEnabled
    }

    private weak var view: NSView?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    /// Display intervals observed while the gesture recorder is alive. The link
    /// intentionally survives for the quiet settle window, but only the prefix
    /// through one interval after the last tick that observed a camera step
    /// belongs to the gesture's frame statistics. That following interval is
    /// load-bearing: a display-link camera commit can schedule AppKit/CA work
    /// after this recorder's callback, delaying the next callback. Everything
    /// beyond it is quiet tail and would make a bad zoom look healthier.
    private struct FrameInterval {
        let milliseconds: Double
        let deliversCameraStep: Bool
    }
    private var intervals: [FrameInterval] = []
    private var lastDeliveryIntervalIndex: Int?
    /// Set by `noteCameraStep`, consumed by the next display-link tick. If the
    /// final camera commit blocks the main thread, that delayed tick's long
    /// interval remains marked as active and therefore remains in the result.
    private var hasUndeliveredCameraStep = false
    private var cameraStepsThisGesture = 0
    private var lastCameraStep: CFTimeInterval = 0
    private var gestureActive = false
    private var settleTimer: Timer?
    private let settleSeconds: CFTimeInterval = 0.25
    private let hudPublishInterval: CFTimeInterval = 0.25
    private let hudRollingFrameCount = 30
    private var lastHUDPublishTimestamp: CFTimeInterval = 0
    private let onGestureStats: ((GestureStats) -> Void)?

    /// QA: the most recent completed gesture, so a check or a probe can read the
    /// numbers without scraping stdout.
    private(set) var lastGesture: GestureStats?

    struct GestureStats: Sendable, Equatable {
        let frames: Int
        let cameraSteps: Int
        let p50Ms: Double
        let p95Ms: Double
        let worstMs: Double
        /// Time-weighted throughput over the represented intervals. Unlike the
        /// reciprocal of p50, long stalls lower this number immediately.
        let averageFps: Double
        /// Frames that overran the display's own cadence — the honest "dropped"
        /// count, measured against the refresh rate actually in use rather than
        /// an assumed 60.
        let overBudgetFrames: Int
        let refreshHz: Double

        var medianFps: Double { p50Ms > 0 ? 1_000 / p50Ms : 0 }
    }

    init(view: NSView, onGestureStats: ((GestureStats) -> Void)? = nil) {
        self.view = view
        self.onGestureStats = onGestureStats
    }

    /// Called from `setViewport` on every camera increment.
    func noteCameraStep() {
        guard Self.isEnabled else { return }
        lastCameraStep = CACurrentMediaTime()
        if !gestureActive { beginGesture() }
        // `beginGesture` resets the previous gesture's counters, so account the
        // leading camera commit afterwards. The old order silently lost step 1.
        cameraStepsThisGesture += 1
        hasUndeliveredCameraStep = true
        // The display link is the sampler, but it must not also be the only way a
        // gesture can END: it stops ticking when the window is occluded or the app
        // deactivates, and a gesture that finishes at that moment would never be
        // reported at all. This timer guarantees the flush.
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: settleSeconds * 2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushIfSettled() }
        }
    }

    private func flushIfSettled() {
        guard gestureActive, CACurrentMediaTime() - lastCameraStep >= settleSeconds else { return }
        endGesture(link: displayLink)
    }

    private func beginGesture() {
        guard let view, displayLink == nil else { return }
        gestureActive = true
        intervals.removeAll(keepingCapacity: true)
        lastDeliveryIntervalIndex = nil
        cameraStepsThisGesture = 0
        hasUndeliveredCameraStep = false
        lastTimestamp = 0
        lastHUDPublishTimestamp = 0
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastTimestamp > 0 {
            intervals.append(FrameInterval(
                milliseconds: (now - lastTimestamp) * 1_000,
                deliversCameraStep: hasUndeliveredCameraStep
            ))
            if hasUndeliveredCameraStep {
                lastDeliveryIntervalIndex = intervals.count - 1
            }
        }
        lastTimestamp = now
        // The first tick establishes the timestamp and can deliver the leading
        // camera step even though there is no preceding interval to time.
        hasUndeliveredCameraStep = false
        if lastHUDPublishTimestamp == 0 { lastHUDPublishTimestamp = now }
        if Self.isHUDEnabled,
           let lastDeliveryIntervalIndex,
           intervals.count >= 2,
           now - lastHUDPublishTimestamp >= hudPublishInterval {
            lastHUDPublishTimestamp = now
            // Include one interval after the tick that observed the final step:
            // AppKit/CA can commit that camera change after our callback and
            // delay the next one. Take at most 30 values directly from that
            // active prefix. Do not map
            // the whole gesture on every display callback merely to discard its
            // tail; instrumentation must not become frame-rate work itself.
            let activeEnd = min(lastDeliveryIntervalIndex + 1, intervals.count - 1)
            let first = max(0, activeEnd - hudRollingFrameCount + 1)
            let rolling = intervals[first...activeEnd].map(\.milliseconds)
            onGestureStats?(makeStats(intervals: rolling, cameraSteps: cameraStepsThisGesture))
        }
        if CACurrentMediaTime() - lastCameraStep > settleSeconds { endGesture(link: link) }
    }

    private func makeStats(intervals: [Double], cameraSteps: Int) -> GestureStats {
        let refreshHz: Double = {
            let nominal = view?.window?.screen?.maximumFramesPerSecond ?? 60
            return Double(max(nominal, 1))
        }()
        let budgetMs = 1_000 / refreshHz
        let sorted = intervals.sorted()
        func percentile(_ p: Double) -> Double {
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
            return sorted[index]
        }
        let meanMs = intervals.reduce(0, +) / Double(max(intervals.count, 1))
        return GestureStats(
            frames: intervals.count,
            cameraSteps: cameraSteps,
            p50Ms: percentile(0.50),
            p95Ms: percentile(0.95),
            worstMs: sorted.last ?? 0,
            averageFps: meanMs > 0 ? 1_000 / meanMs : 0,
            overBudgetFrames: intervals.filter { $0 > budgetMs * 1.5 }.count,
            refreshHz: refreshHz
        )
    }

    private func endGesture(link: CADisplayLink?) {
        link?.invalidate()
        displayLink = nil
        settleTimer?.invalidate()
        settleTimer = nil
        gestureActive = false
        let activeIntervals = Self.activeIntervals(in: intervals)
        guard activeIntervals.count >= 2 else { return }

        // The display's own cadence is the budget. On a ProMotion panel that is
        // 8.3 ms; on an external 60 Hz monitor it is 16.7 ms. Asserting a fixed
        // 60 would call a perfect 120 Hz gesture a failure and vice versa.
        let stats = makeStats(intervals: activeIntervals, cameraSteps: cameraStepsThisGesture)
        let budgetMs = 1_000 / stats.refreshHz
        lastGesture = stats
        // Replace the rolling live sample with the whole-gesture result once the
        // gesture closes.
        onGestureStats?(stats)
        guard Self.isLoggingEnabled else { return }
        let line = String(
                format: "[frame-stats] gesture: %d frames, %d camera steps @ %.0f Hz (%.1f ms budget) — p50 %.2f ms (%.0f fps), p95 %.2f ms, worst %.2f ms, %d late (%.0f%%)\n",
                stats.frames, stats.cameraSteps, stats.refreshHz, budgetMs,
                stats.p50Ms, stats.medianFps, stats.p95Ms, stats.worstMs,
                stats.overBudgetFrames,
                Double(stats.overBudgetFrames) / Double(max(stats.frames, 1)) * 100
            )
        FileHandle.standardError.write(Data(line.utf8))
        // A GUI app launched through `open` (which is the only correct way to
        // launch it — see scripts/dev-app.sh) has no terminal to write to, so
        // dogfooding needs a file sink to get the numbers back out.
        if let path = ProcessInfo.processInfo.environment["CONTINUUM_FRAME_STATS_FILE"] {
            let url = URL(fileURLWithPath: path)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Keep the contiguous gesture window through one interval after the last
    /// tick that observed a camera commit. Intervals between camera deliveries
    /// stay in the window; only the smooth tail after the final delivery is
    /// removed.
    private static func activeIntervals(in samples: [FrameInterval]) -> [Double] {
        guard let finalDelivery = samples.lastIndex(where: \.deliversCameraStep) else { return [] }
        let activeEnd = min(finalDelivery + 1, samples.count - 1)
        return samples[...activeEnd].map(\.milliseconds)
    }

    /// Deterministic QA seam for the interval-attribution rule. This avoids a
    /// live CADisplayLink in the camera-driver check while exercising the same
    /// selector used by rolling and completed gesture statistics.
    static func qaActiveIntervals(
        _ samples: [(milliseconds: Double, deliversCameraStep: Bool)]
    ) -> [Double] {
        activeIntervals(in: samples.map {
            FrameInterval(milliseconds: $0.milliseconds, deliversCameraStep: $0.deliversCameraStep)
        })
    }

    var qaCameraStepCount: Int { cameraStepsThisGesture }

    /// Stop a recorder created only to inspect its leading-step accounting.
    /// Unlike `endGesture`, this deliberately publishes no partial result.
    func qaCancel() {
        displayLink?.invalidate()
        displayLink = nil
        settleTimer?.invalidate()
        settleTimer = nil
        gestureActive = false
    }
}
