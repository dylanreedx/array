import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Session context under the title bar: branch, checkout warnings and awareness.
/// The legacy type name is retained for existing zoom/theme probes. Identity and
/// operational status belong to the tile bar; live elapsed time belongs to the
/// compact activity row. Standalone probes can still exercise the elapsed lane.
@MainActor
final class AgentTileHeaderView: NSView, TokenThemed, AgentPageZoomScalable {
    static let stopActionTitle = "Stop agent run"
    static let detachActionTitle = "Detach agent view"

    static var preferredHeight: CGFloat {
        preferredHeight(zoom: .default)
    }

    static func preferredHeight(zoom: AgentPageZoom) -> CGFloat {
        CGFloat(BranchChipNSView.preferredHeight(zoom: zoom) + zoom.scaled(8))
    }

    /// This header's rung of the tile's page zoom. `.default` until the tile's
    /// subtree walk delivers one; every derivation below is an exact identity
    /// at 100%.
    private(set) var pageZoom: AgentPageZoom = .default

    private let elapsedLabel = NSTextField(labelWithString: "")
    private let branchChip = BranchChipNSView()
    private var presentation: AgentTileStatePresenter.Presentation?
    private var elapsedTimer: Timer?

    // Every constant that follows the page zoom is held, not baked into an
    // activated anchor a later rung could not reach.
    private var row: NSStackView?
    private weak var statusBadge: NSView?
    private var elapsedWidth: NSLayoutConstraint?

    /// Production uses the compact row's single elapsed clock. The standalone
    /// elapsed lane remains available to the formatter/geometry probes.
    var showsElapsedTime = true {
        didSet {
            updateElapsed(now: AgentElapsedClock.now())
            updateTimer(startedAt: presentation?.startedAt)
            updateVisibility()
        }
    }

    func installStatusBadge(_ badge: NSView) {
        statusBadge = badge
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        row?.addArrangedSubview(badge)
        updateVisibility()
    }

    func updateVisibility() {
        isHidden = branchChip.isHidden && statusBadge?.isHidden != false && !showsElapsed
    }


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        elapsedLabel.font = .token(.captionMono, zoom: pageZoom)
        elapsedLabel.alignment = .left
        elapsedLabel.lineBreakMode = .byClipping
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)


        let row = NSStackView(views: [elapsedLabel, NSView(), branchChip])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = CGFloat(pageZoom.scaled(Space.m))
        row.edgeInsets = contextInsets
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        self.row = row

        let elapsedWidth = elapsedLabel.widthAnchor.constraint(
            equalToConstant: Self.elapsedColumnWidth(zoom: pageZoom))
        self.elapsedWidth = elapsedWidth

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            elapsedWidth,
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent checkout context")
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit { elapsedTimer?.invalidate() }

    func apply(_ next: AgentTileStatePresenter.Presentation) {
        presentation = next
        branchChip.apply(next.branch)
        updateElapsed(now: AgentElapsedClock.now())
        updateTimer(startedAt: next.startedAt)
        setAccessibilityValue(next.branch?.tooltip)
        updateVisibility()
        applyTokens()
    }

    func applyTokens() {
        elapsedLabel.textColor = TextToken.textSecondary.color.nsColor(for: effectiveTokenTheme)
        branchChip.applyTokens()
    }

    private var contextInsets: NSEdgeInsets {
        let row = NSEdgeInsets(Inset.row, zoom: pageZoom)
        return NSEdgeInsets(top: CGFloat(pageZoom.scaled(4)), left: row.left,
                            bottom: CGFloat(pageZoom.scaled(4)), right: row.right)
    }

    /// Re-derives every metric this header owns from `zoom`. Same contract as
    /// `applyTokens()`: idempotent, and safe on a header already showing a
    /// presentation — it touches no string, no timer and no accessibility value.
    ///
    /// The chip and the overflow button are `AgentPageZoomScalable` themselves and
    /// are reached by the tile's subtree walk, so this does not re-apply to them.
    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        elapsedLabel.font = .token(.captionMono, zoom: pageZoom)
        row?.spacing = CGFloat(pageZoom.scaled(Space.m))
        row?.edgeInsets = contextInsets
        elapsedWidth?.constant = Self.elapsedColumnWidth(zoom: pageZoom)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private var showsElapsed: Bool {
        showsElapsedTime && presentation?.startedAt != nil
            && (statusBadge?.isHidden != false || bounds.width >= CGFloat(pageZoom.scaled(520)))
    }

    override func layout() {
        // The duration remains in the spoken status. At narrow widths a live
        // status badge takes this space so both branch and status stay legible.
        elapsedLabel.isHidden = !showsElapsed
        super.layout()
    }

    private func updateTimer(startedAt: Date?) {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        guard showsElapsedTime, startedAt != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsed(now: AgentElapsedClock.now()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    /// The header lane measures the rendered prefixed label, not the bare
    /// formatter value. The separator is decorative on screen but still occupies
    /// drawable width, so leaving it out would clip the timer around ten minutes.
    private static var elapsedColumnWidth: CGFloat {
        elapsedColumnWidth(zoom: .default)
    }

    private static func elapsedColumnWidth(zoom: AgentPageZoom) -> CGFloat {
        let font = NSFont.token(.captionMono, zoom: zoom)
        // Measured over what the formatter EMITS at every branch boundary, prefix
        // included — not over a hand-kept list. An earlier attempt measured the bare
        // forms and clipped a nine-glyph string; the list it measured was also 8pt
        // short of the rendered need, which is exactly the drift a derived set removes.
        let width = AgentElapsedFormatter.widestFormProbes.map { seconds in
            Double(ceil((AgentElapsedFormatter.prefixedLabel(seconds) as NSString)
                .size(withAttributes: [.font: font]).width))
                + zoom.scaled(Metrics.cellTextInset)
        }.max() ?? zoom.scaled(Metrics.cellTextInset)
        return CGFloat(width)
    }

    private func updateElapsed(now: Date) {
        guard let current = presentation,
              let start = current.startedAt else {
            elapsedLabel.stringValue = ""
            elapsedLabel.isHidden = true
            return
        }
        let interval = now.timeIntervalSince(start)
        let seconds = interval.isFinite ? max(0, Int(interval.rounded(.down))) : 0
        let label = AgentElapsedFormatter.elapsedLabel(interval)
        elapsedLabel.stringValue = AgentElapsedFormatter.headerPrefix + label
        elapsedLabel.isHidden = !showsElapsed
        // Keep the spoken value free of the decorative separator. The numeric
        // duration remains live on each tick; the bounded formatter owns the visual
        // lane rather than replacing the established accessibility vocabulary.
        setAccessibilityValue("\(seconds) seconds elapsed")
        // Deliberately no `needsLayout`: the mono label has stable reserved width,
        // and a timer tick must not invalidate the transcript below this view.
    }

    var qaBranchFrame: NSRect { branchChip.convert(branchChip.bounds, to: self) }

    var qaName: String { presentation?.name ?? "" }
    var qaState: String { presentation?.stateLabel ?? "" }
    var qaElapsed: String? { elapsedLabel.isHidden ? nil : elapsedLabel.stringValue }
    var qaBranch: String? { branchChip.isHidden ? nil : branchChip.qaText }
    var qaBranchIsWarning: Bool { !branchChip.isHidden && branchChip.qaIsWarning }
    var qaBranchTooltip: String? { branchChip.isHidden ? nil : branchChip.toolTip }
    var qaTimerIsActive: Bool { elapsedTimer?.isValid == true }
    // Geometry probes read shell-space frames so lane assertions compare like
    // coordinates regardless of the internal stack nesting.
    var qaNameFrame: NSRect? { nil }
    var qaElapsedFrame: NSRect? { elapsedLabel.superview.map { $0.convert(elapsedLabel.frame, to: self) } }

    /// Deterministic action/timer seams used by the existing supervisor check.
    /// They invoke the same callbacks as the production menu items and drive the
    /// same elapsed-label update as the one-second timer; no parallel QA behavior.
    func qaTick(now: Date) { updateElapsed(now: now) }
}

/// NSControl supplies target/action, keyboard focus and accessibility without
/// leaking an Aqua button bezel into the header.
@MainActor
final class AgentTileOverflowButton: NSControl, TokenThemed, AgentPageZoomScalable {
    private let imageView = NSImageView(frame: .zero)
    private var isPressed = false
    private var chromeGlyphWidth: CGFloat = 13

    // SF Symbols include transparent side bearings. Measure this one cached
    // bitmap once so the requested width describes the painted dots, rather
    // than their image box. The same template serves every chrome bucket.
    private static let glyphImage = CanvasSymbolImage.image(named: "ellipsis", pointSize: 13)
    private static let glyphInkBounds: NSRect = {
        guard let image = glyphImage,
              let rep = image.representations.first as? NSBitmapImageRep else {
            return NSRect(x: 0, y: 0, width: 13, height: 5)
        }
        var left = rep.pixelsWide, right = -1, top = rep.pixelsHigh, bottom = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        guard right >= left else { return NSRect(origin: .zero, size: image.size) }
        let sx = image.size.width / CGFloat(rep.pixelsWide)
        let sy = image.size.height / CGFloat(rep.pixelsHigh)
        // Bitmap rows start at the top; the control's image coordinates start below.
        return NSRect(x: CGFloat(left) * sx, y: CGFloat(rep.pixelsHigh - bottom - 1) * sy,
                      width: CGFloat(right - left + 1) * sx, height: CGFloat(bottom - top + 1) * sy)
    }()

    /// This button's rung of the tile's page zoom, delivered by the tile's
    /// subtree walk. Identity at 100%.
    private(set) var pageZoom: AgentPageZoom = .default

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.image = Self.glyphImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Agent actions")
        setAccessibilityHelp("Stop the running agent process or detach this view. Detaching does not stop, archive, or delete the agent.")
        toolTip = "Agent actions"
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        guard let image = imageView.image, image.size.width > 0 else { return }
        let scale = min(chromeGlyphWidth, bounds.width) / Self.glyphInkBounds.width
        let width = image.size.width * scale
        let height = image.size.height * scale
        let rect = NSRect(x: bounds.midX - Self.glyphInkBounds.midX * scale,
                          y: bounds.midY - Self.glyphInkBounds.midY * scale,
                          width: width, height: height)
        if imageView.frame != rect { imageView.frame = rect }
    }

    /// The title bar delivers a bucketed world width, independently of page zoom.
    /// Keep the shared bitmap/template cache: zoom only resizes the image box.
    func applyChromeGlyphWidth(_ width: CGFloat) {
        guard chromeGlyphWidth != width else { return }
        chromeGlyphWidth = width
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        applyTokens()
        defer { isPressed = false; applyTokens() }
        _ = sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            _ = sendAction(action, to: target)
        } else {
            super.keyDown(with: event)
        }
    }

    // Keyboard focus is the SYSTEM focus ring, drawn by AppKit around this
    // mask at the user's own accessibility settings. It replaced a hand-drawn
    // 2pt stroke: the system ring is the one border the app-wide 0.5pt
    // ceiling exempts, because it is the accessibility affordance.
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = CGFloat(pageZoom.scaled(Radius.card))
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        imageView.contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
        alphaValue = isPressed ? 0.72 : 1
        needsDisplay = true
    }

    /// The glyph box and the focus-ring radius are laid out in `layout()`/`draw`,
    /// so re-deriving them is a matter of invalidating both.
    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        applyTokens()
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        applyTokens()
        return result
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }
}

/// The elapsed readout clock of the agent header and the sidebar inbox (rows and
/// their live tick). Wall time. Only the film build (`-DARRAY_FILM`) can redirect
/// it: the film renders frames slower than real time and substitutes its film clock
/// so "Working · 4s" means four seconds of footage, not of rendering.
enum AgentElapsedClock {
    #if ARRAY_FILM
    /// Written only on the main thread, by the film director.
    nonisolated(unsafe) static var now: () -> Date = { Date() }
    #else
    @inline(__always) static func now() -> Date { Date() }
    #endif
}
