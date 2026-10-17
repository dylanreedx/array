import AppKit
import ContinuumRevivedCore

/// The scrolling waveform inside the dictation pill.
///
/// The bars are drawn, not layered: 48 rects into one small backing store, and
/// only when a bar scrolls (20 times a second). The audio tap's level events
/// only feed the envelope; they never redraw. The pill assigns `barColor`, so
/// this view paints no layer colour of its own.
@MainActor
final class ComposerDictationStripView: NSView {
    enum Mode: Equatable {
        case preparing(downloadingModel: Bool)
        case listening
        case finalizing
    }

    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 1
    /// Bars scroll at this rate; the meter's bucket peak covers the gap.
    static let advanceInterval: CFTimeInterval = 1.0 / 20.0

    var barColor: NSColor? { didSet { needsDisplay = true } }
    private(set) var meter = DictationLevelMeter()
    private(set) var mode: Mode = .listening
    private var displayLink: CADisplayLink?
    private var lastLevelTime: CFTimeInterval?
    private var lastTick: CFTimeInterval?
    private var sinceAdvance: CFTimeInterval = 0
    private(set) var qaRedrawCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func setMode(_ newMode: Mode) {
        mode = newMode
        if case .preparing = newMode { meter.reset() }
        updateDisplayLink()
        needsDisplay = true
    }

    /// One `.level` event. Feeds the envelope only.
    func record(level: Float) {
        let now = CACurrentMediaTime()
        let delta = lastLevelTime.map { min(now - $0, 0.1) } ?? 0.02
        lastLevelTime = now
        meter.record(level: level, deltaTime: Float(delta))
    }

    func reset() {
        meter.reset()
        lastLevelTime = nil
        lastTick = nil
        sinceAdvance = 0
        needsDisplay = true
    }

    /// The display-link body, also driven directly by checks.
    func tick(elapsed: CFTimeInterval) {
        sinceAdvance += elapsed
        var advanced = false
        while sinceAdvance >= Self.advanceInterval {
            sinceAdvance -= Self.advanceInterval
            switch mode {
            case .listening: meter.advanceBar()
            case .finalizing: meter.decay(deltaTime: Float(Self.advanceInterval))
            case .preparing: break
            }
            advanced = true
        }
        if advanced {
            qaRedrawCount += 1
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = bounds.height
        guard height > 0, let barColor else { return }
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let bars: [Float]
        if case .preparing = mode {
            bars = Array(repeating: DictationLevelMeter.restingLevel, count: DictationLevelMeter.defaultBarCount)
        } else if reducedMotion {
            bars = Array(repeating: max(meter.envelope, DictationLevelMeter.restingLevel), count: DictationLevelMeter.defaultBarCount)
        } else {
            bars = meter.displayBars
        }
        barColor.setFill()
        // The newest bars that fit: a pill narrower than the meter's history
        // drops the oldest, never the bar being spoken now.
        let fitting = max(0, Int((bounds.width + Self.barGap) / (Self.barWidth + Self.barGap)))
        for (index, level) in bars.suffix(fitting).enumerated() {
            let barHeight = max(Self.barWidth, CGFloat(level) * height)
            let rect = NSRect(
                x: CGFloat(index) * (Self.barWidth + Self.barGap),
                y: floor((height - barHeight) / 2),
                width: Self.barWidth, height: barHeight)
            NSBezierPath(roundedRect: rect, xRadius: Self.barWidth / 2, yRadius: Self.barWidth / 2).fill()
        }
    }

    // MARK: - Display link: alive only while there is motion to show

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDisplayLink()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateDisplayLink()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateDisplayLink()
    }

    private func updateDisplayLink() {
        let wantsMotion: Bool
        switch mode {
        case .listening, .finalizing: wantsMotion = true
        case .preparing: wantsMotion = false
        }
        let shouldRun = wantsMotion && window != nil && !isHiddenOrHasHiddenAncestor
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldRun, displayLink == nil {
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 20)
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastTick = nil
        } else if !shouldRun, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = lastTick.map { min(now - $0, 1.0 / 15.0) } ?? 0
        lastTick = now
        tick(elapsed: elapsed)
    }

    var qaDisplayLinkRunning: Bool { displayLink != nil }

    isolated deinit {
        displayLink?.invalidate()
    }
}
