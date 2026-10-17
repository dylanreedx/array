import Foundation

/// The waveform's arithmetic, kept out of the view so it can be asserted
/// without a screen, a display link or a microphone.
///
/// Three things separate a level meter that reads as "quality" from one that
/// reads as cheap, and all three are here rather than in the drawing code:
///
/// 1. **Perceptual scale.** Speech at a normal level is a small fraction of full
///    scale, so a linear amplitude bar barely moves. Levels are converted to
///    decibels and mapped from a floor, which is why normal speech fills most of
///    the height.
/// 2. **Envelope following.** Raw per-buffer RMS is visibly jittery. A fast
///    attack and a slow release make the bars track speech without flickering.
/// 3. **A resting floor.** A meter that sits at exactly zero during silence
///    reads as broken rather than listening.
///
/// Time is always passed in explicitly. The meter never reads a clock, so a
/// check gets identical output for identical input.
public struct DictationLevelMeter: Equatable, Sendable {
    /// Number of history buckets the waveform draws.
    public static let defaultBarCount = 48
    /// Input quieter than this maps to zero. Chosen so room tone reads as
    /// silence while quiet speech still moves the bars.
    public static let floorDecibels: Float = -55
    /// The height bars hold while listening to silence.
    public static let restingLevel: Float = 0.06
    /// Time constants for the envelope follower, in seconds.
    public static let attackSeconds: Float = 0.02
    public static let releaseSeconds: Float = 0.15

    /// Oldest first, newest last — draw order, left to right.
    public private(set) var bars: [Float]
    /// Smoothed instantaneous level.
    public private(set) var envelope: Float = 0
    /// Peak of the envelope since the last `advanceBar()`.
    private var bucketPeak: Float = 0

    public init(barCount: Int = DictationLevelMeter.defaultBarCount) {
        bars = Array(repeating: 0, count: max(1, barCount))
    }

    /// Map a raw RMS amplitude (0...1) onto a perceptual 0...1 scale.
    public static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        guard decibels > floorDecibels else { return 0 }
        return min(1, (decibels - floorDecibels) / -floorDecibels)
    }

    /// Feed one audio buffer's RMS. `deltaTime` is that buffer's duration, so
    /// the envelope behaves identically at any buffer size.
    public mutating func record(rms: Float, deltaTime: Float) {
        record(level: Self.normalized(rms: rms), deltaTime: deltaTime)
    }

    /// Feed a level the engine has already normalized — `DictationEngineEvent
    /// .level` carries the perceptual 0...1 value, and normalizing it again
    /// would flatten speech to the floor.
    public mutating func record(level: Float, deltaTime: Float) {
        let target = min(max(level, 0), 1)
        let tau = target > envelope ? Self.attackSeconds : Self.releaseSeconds
        // Standard one-pole follower. A non-positive dt would divide by zero or
        // run the filter backwards; snap instead.
        let coefficient = deltaTime > 0 ? 1 - exp(-deltaTime / tau) : 1
        envelope += (target - envelope) * min(max(coefficient, 0), 1)
        bucketPeak = max(bucketPeak, envelope)
    }

    /// Close the current bucket and scroll the history one bar left. Called by
    /// the view's display link, NOT by the audio tap — the tap fires ~100×/s and
    /// repainting at that rate is display work the canvas cannot afford.
    public mutating func advanceBar() {
        bars.removeFirst()
        bars.append(bucketPeak)
        bucketPeak = envelope
    }

    /// What the view draws: history with the resting floor applied, so a
    /// listening meter is never completely flat.
    public var displayBars: [Float] {
        bars.map { max($0, Self.restingLevel) }
    }

    /// Decay everything toward silence — the finalize animation. The meter
    /// settles to the floor over roughly `releaseSeconds` rather than the
    /// waveform being cut mid-flight.
    public mutating func decay(deltaTime: Float) {
        let coefficient = deltaTime > 0 ? 1 - exp(-deltaTime / Self.releaseSeconds) : 1
        let factor = 1 - min(max(coefficient, 0), 1)
        envelope *= factor
        bucketPeak *= factor
        for index in bars.indices { bars[index] *= factor }
    }

    /// Back to a cold meter. Used on cancel, where nothing should linger.
    public mutating func reset() {
        for index in bars.indices { bars[index] = 0 }
        envelope = 0
        bucketPeak = 0
    }

    /// True once the meter has settled far enough that the view can collapse.
    public var isSilent: Bool {
        envelope < 0.001 && bars.allSatisfy { $0 < 0.001 }
    }
}
