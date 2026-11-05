import AppKit
import ContinuumRevivedCore

/// Counts real driver applies; no run loop, monitor hardware or stopwatch.
enum CanvasNativePacingChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @MainActor
    static func run() throws {
        for hz in [60.0, 120.0, 144.0, 240.0, 59.94] {
            var now: TimeInterval = 1_000
            var interval: TimeInterval? = 1 / hz
            var viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
            var applies = 0
            let driver = CanvasCameraDriver(
                tuning: .init(), currentViewport: { viewport },
                applyViewport: { viewport = $0; applies += 1 },
                makeDisplayLink: { _, _ in nil },
                nativeRefreshInterval: { interval }
            )
            driver.nowProvider = { now }
            driver.noteScrollPan(dx: 1, dy: 0, location: .zero)
            now += interval! * 0.9
            driver.noteScrollPan(dx: 2, dy: 0, location: .zero)
            guard applies == 1 else {
                throw Failure(description: "\(hz) Hz: input inside the native interval replayed \(applies) applies")
            }
            now += interval! * 0.2
            driver.noteScrollPan(dx: 3, dy: 0, location: .zero)
            guard applies == 2, viewport.x == -6 else {
                throw Failure(description: "\(hz) Hz: native interval elapsed but newest input did not apply; applies=\(applies), x=\(viewport.x)")
            }
            // Same live driver, window moved to another monitor. Reading once
            // at construction would leave the old display's pacing in force.
            interval = 1 / 48.0
            now += 0.010
            driver.noteScrollPan(dx: 4, dy: 0, location: .zero)
            guard applies == 2 else {
                throw Failure(description: "screen transition must immediately use the new 48 Hz interval")
            }
            now += 0.012
            driver.noteScrollPan(dx: 5, dy: 0, location: .zero)
            guard applies == 3, viewport.x == -15 else {
                throw Failure(description: "screen transition dropped accumulated pan input")
            }
            // Missing/invalid screen metadata must retain the no-screen fallback.
            for missing in [nil, 0, -.infinity, .nan] as [TimeInterval?] {
                interval = missing
                now += 0.009
                driver.noteScrollPan(dx: 1, dy: 0, location: .zero)
                guard !driver.qaHasPendingInput else {
                    throw Failure(description: "invalid screen interval stranded input")
                }
            }
            driver.qaMarkSettledNow()
            print("native camera pacing: \(hz) Hz, screen transition, invalid metadata passed")
        }
    }
}
