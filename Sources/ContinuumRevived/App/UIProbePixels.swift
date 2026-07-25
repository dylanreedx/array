import AppKit
import ContinuumRevivedCore

/// Numeric probes over the `UIProbe` **bitmap** — the layer that catches "the
/// model says it's fine but the render is wrong".
///
/// The contrast gate (`UIProbeContrast`) reads colours off view properties, so a
/// background painted in a custom `draw(_:)` override, a glyph the text system
/// never actually composited, or a border a rounded-corner mask ate are all
/// invisible to it. These two probes read the pixels that were really drawn:
///
/// - `expectLegibleText(in:)` — the label's rect must be *modulated*. Text that
///   never landed produces a flat rect.
/// - `expectVisibleBorder(of:)` — the border band must differ from the fill just
///   inside it.
///
/// Deliberately **flatness**, not legibility: WCAG ratios are `UIProbeContrast`'s
/// job and are measured there against the real colour pairs. A pixel gate that
/// tried to enforce a ratio would duplicate that gate badly (it cannot separate
/// glyph coverage from glyph colour) and would go red on the same known-bad
/// pairs. What only a pixel read can answer is: did anything get drawn at all.
@MainActor
enum UIProbePixels {
    struct PixelError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func fail(_ message: String) -> PixelError { PixelError(message: message) }

    // MARK: - Thresholds
    //
    // Both are **derived from measurement**, not chosen: the numbers below are the
    // real worst cases over the managed-agent tile in both appearances, printed by
    // this check (`worst text spread` / `worst border delta`) at the time it was
    // written.
    //
    // Luminance is the gamma-encoded proxy `0.2126R + 0.7152G + 0.0722B` over
    // deviceRGB components — the same one `UIProbe.runUIProbeChecks` uses for its
    // layer witness. It is not WCAG relative luminance (no linearisation), and it
    // must not be: this gate compares *drawn* values, and the encoded space is the
    // one the bitmap is actually in.

    /// Minimum `max − min` luminance across a label's rect.
    ///
    /// Measured worst real case over the managed-agent tile: **0.405** since P1.10
    /// put the tile on `DesignTokens` (an `NSButton` title in `.aqua`). It was
    /// **0.141** before — a label where `.labelColor` resolved to black at 85% over
    /// the transcript card's hardcoded dark fill: a pair that was unreadable, which
    /// `UIProbeContrast` said so about while this gate still counted it as *drawn*.
    /// A label painted in its own background measures **0.000** (measured, both
    /// appearances, on the fixture and on the real card). Threshold 0.05 is left
    /// where it was: it now sits 8x under the worst real case, and this gate's job is
    /// to separate "not drawn" from "drawn badly" without arbitrating the second.
    static let minimumTextLuminanceSpread = 0.05

    /// Minimum |border − fill| luminance across a scanline crossing an edge.
    ///
    /// Measured worst real case: **0.106** since P1.10 (the tile's own outline in
    /// `.aqua`, which is still `TileNSView`'s white@0.25 literal — P1.11's file). It
    /// was **0.093** before, `ApprovalDockView`'s `systemOrange@0.55` edge over its
    /// own `systemOrange@0.14` fill in `.darkAqua`; the dock now paints
    /// `accentApproval` on `SurfaceToken.overlay` and measures far above that. A
    /// border painted in the fill colour measures **0.000**. Threshold 0.03 is left
    /// where it was, 3.5x under the worst real case.
    static let minimumBorderLuminanceDelta = 0.03

    // Band geometry, in **bitmap pixels**, for the border scanline. Antialiasing
    // means the exact border pixel varies, so a band is sampled, never one pixel.
    /// The outermost pixel row/column blends with whatever is *behind* the view
    /// (the parent's fill), so it is skipped: including it would let a border that
    /// matches its own fill pass on the parent's colour alone.
    private static let borderEdgeSkipPixels = 1
    /// Antialiasing between the border and the fill inside it.
    private static let borderToFillGapPixels = 2
    /// How much undisturbed fill to average as the reference.
    private static let fillBandPixels = 4

    // MARK: - Bitmap coordinates

    /// A rect in bitmap pixels. `NSBitmapImageRep` addresses row 0 at the **top**;
    /// the probe host is an unflipped `NSView` with its origin at the bottom — so
    /// the conversion below flips y explicitly, and `runPixelChecks` validates it
    /// against a known-coloured fixture patch at a deliberately asymmetric offset
    /// before it trusts any measurement.
    struct PixelRect: Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    /// The part of `view` that actually reached the bitmap, in pixels.
    static func renderedRect(of view: NSView, in probe: UIProbe.Probed) throws -> PixelRect {
        try bitmapRect(of: view, rect: visiblePortion(of: view), in: probe)
    }

    /// `bounds` intersected with `visibleRect`, in the view's own coordinates.
    ///
    /// Both terms are needed. `visibleRect` alone is **not** bounded by `bounds`:
    /// AppKit only subtracts ancestors that actually clip (`clipsToBounds`, an
    /// `NSClipView`), so for a label in a plain container it comes back as the whole
    /// window rect expressed in label coordinates — measured: a 140x18 label reported
    /// `visibleRect` (-40, -38, 240, 140). `bounds` alone would ignore the transcript
    /// clip view and sample a scrolled-away card's rect as if it had been drawn.
    static func visiblePortion(of view: NSView) -> NSRect {
        view.bounds.intersection(view.visibleRect)
    }

    /// `rect`, given in `view`'s coordinates, in `probe.hostRep` pixels.
    static func bitmapRect(of view: NSView, rect viewRect: NSRect, in probe: UIProbe.Probed) throws -> PixelRect {
        let host = probe.host
        let rep = probe.hostRep
        guard host.bounds.width > 0, host.bounds.height > 0 else {
            throw fail("\(probe.spec.id): probe host has no size")
        }
        // `bitmapImageRepForCachingDisplay` may be 2x on retina, so the rect is
        // scaled rather than assumed 1:1. Both axes are checked: a mismatch would
        // silently skew every sample.
        let scaleX = Double(rep.pixelsWide) / host.bounds.width
        let scaleY = Double(rep.pixelsHigh) / host.bounds.height
        guard abs(scaleX - scaleY) < 0.001 else {
            throw fail(String(
                format: "%@: non-uniform bitmap scale (%.3f x %.3f)", probe.spec.id, scaleX, scaleY
            ))
        }
        let rect = view.convert(viewRect, to: host)
        let x = Int((rect.minX * scaleX).rounded())
        // Flip: the bitmap's row 0 is the host's top edge.
        let y = Int(((host.bounds.height - rect.maxY) * scaleY).rounded())
        let width = Int((rect.width * scaleX).rounded())
        let height = Int((rect.height * scaleY).rounded())
        guard width > 0, height > 0 else {
            throw fail("\(probe.spec.id): \(describe(view)) maps to a \(width)x\(height)px rect")
        }
        guard x >= 0, y >= 0, x + width <= rep.pixelsWide, y + height <= rep.pixelsHigh else {
            throw fail(
                "\(probe.spec.id): \(describe(view)) maps outside the bitmap — "
                    + "\(width)x\(height) at (\(x),\(y)) in \(rep.pixelsWide)x\(rep.pixelsHigh)px"
            )
        }
        return PixelRect(x: x, y: y, width: width, height: height)
    }

    private static func luminance(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Double? {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }

    // MARK: - Probes

    /// Luminance spread over a label's rect. Returns the measured spread so the
    /// caller can report the worst one it saw.
    @discardableResult
    static func expectLegibleText(in view: NSView, probe: UIProbe.Probed, label: String) throws -> Double {
        let rect = try renderedRect(of: view, in: probe)
        // Bounded cost on a large wrapping label, same idea as VisualSnapshot's grid.
        let step = rect.width * rect.height > 40_000 ? 2 : 1
        var minimum = Double.infinity
        var maximum = -Double.infinity
        var sampled = 0
        var y = rect.y
        while y < rect.y + rect.height {
            var x = rect.x
            while x < rect.x + rect.width {
                if let value = luminance(probe.hostRep, x: x, y: y) {
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                    sampled += 1
                }
                x += step
            }
            y += step
        }
        guard sampled > 0 else {
            throw fail("\(label): no pixels could be read from \(rect.width)x\(rect.height) at (\(rect.x),\(rect.y))")
        }
        let spread = maximum - minimum
        guard spread >= minimumTextLuminanceSpread else {
            throw fail(String(
                format: "%@: text rect is flat — luminance spread %.3f over %d px, needs >= %.3f (min %.3f, max %.3f)",
                label, spread, sampled, minimumTextLuminanceSpread, minimum, maximum
            ))
        }
        return spread
    }

    /// Border-vs-fill luminance delta on scanlines crossing the left and top edges,
    /// gated on the weaker of the two. Returns that delta.
    @discardableResult
    static func expectVisibleBorder(of view: NSView, probe: UIProbe.Probed, label: String) throws -> Double {
        guard let layer = view.layer, layer.borderWidth > 0 else {
            throw fail("\(label): view paints no border, so there is nothing to probe")
        }
        // Unlike the text probe, this one needs the view's own edges, so a partly
        // clipped view is the caller's to skip (`isFullyRendered`) — measuring a
        // missing edge would report a colour bug for a scroll offset.
        guard isFullyRendered(view) else {
            throw fail("\(label): view is clipped (\(visiblePortion(of: view)) of \(view.bounds)), so its border edges are not all in the bitmap")
        }
        let rect = try bitmapRect(of: view, rect: view.bounds, in: probe)
        let scale = Double(probe.hostRep.pixelsWide) / probe.host.bounds.width
        let borderPixels = max(1, Int((Double(layer.borderWidth) * scale).rounded()))
        let needed = borderEdgeSkipPixels + borderPixels + borderToFillGapPixels + fillBandPixels
        guard rect.width >= needed * 2, rect.height >= needed * 2 else {
            throw fail(
                "\(label): \(rect.width)x\(rect.height)px is too small to sample a "
                    + "\(needed)px band on both edges"
            )
        }

        /// One scanline: `offset` px from the edge along the crossing axis, sampled
        /// at the middle of the other axis (well clear of the corner radius).
        func delta(edge: String, sample: (Int) -> Double?) throws -> Double {
            var border: [Double] = []
            var fill: [Double] = []
            for offset in 0..<needed {
                guard let value = sample(offset) else {
                    throw fail("\(label): could not read the \(edge) edge scanline at offset \(offset)")
                }
                if offset >= borderEdgeSkipPixels, offset < borderEdgeSkipPixels + borderPixels {
                    border.append(value)
                } else if offset >= borderEdgeSkipPixels + borderPixels + borderToFillGapPixels {
                    fill.append(value)
                }
            }
            guard !border.isEmpty, !fill.isEmpty else {
                throw fail("\(label): \(edge) edge sampled no border or no fill pixels")
            }
            let reference = fill.reduce(0, +) / Double(fill.count)
            let extreme = border.max(by: { abs($0 - reference) < abs($1 - reference) }) ?? reference
            return abs(extreme - reference)
        }

        let midY = rect.y + rect.height / 2
        let midX = rect.x + rect.width / 2
        let left = try delta(edge: "left") { luminance(probe.hostRep, x: rect.x + $0, y: midY) }
        let top = try delta(edge: "top") { luminance(probe.hostRep, x: midX, y: rect.y + $0) }
        let weakest = min(left, top)
        guard weakest >= minimumBorderLuminanceDelta else {
            throw fail(String(
                format: "%@: border is invisible — luminance delta %.3f (left %.3f, top %.3f), needs >= %.3f",
                label, weakest, left, top, minimumBorderLuminanceDelta
            ))
        }
        return weakest
    }

    // MARK: - Tree helpers

    private static func describe(_ view: NSView) -> String {
        let name = String(describing: type(of: view))
        if let id = view.identifier?.rawValue { return "\(name)#\(id)" }
        return name
    }

    /// Text this view actually paints, or `nil`. Empty and whitespace-only fields
    /// are `nil` — there are no glyphs to be flat — matching
    /// `UIProbeContrast.textColor(of:)`, which skips the same views for the same
    /// reason.
    /// `NSButton` titles are included — the compose row's Run button is tile chrome
    /// that can stop drawing like any label. A field's *placeholder* is not: AppKit
    /// does not expose the colour it draws one in, so there is nothing to relate a
    /// measurement to, and `UIProbeContrast` skips them for the same reason.
    private static func drawnText(of view: NSView) -> String? {
        let text: String
        if let field = view as? NSTextField {
            text = field.stringValue
        } else if let textView = view as? NSTextView {
            text = textView.string
        } else if let button = view as? NSButton {
            text = button.title
        } else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// The fraction of the view's own area that reached the bitmap. Below
    /// `minimumVisibleTextFraction` a text rect is too clipped to say anything about
    /// — a card scrolled to the clip view's edge shows a sliver of a label, and a
    /// sliver of a glyph run is legitimately flat.
    private static func renderedFraction(of view: NSView) -> Double {
        let area = view.bounds.width * view.bounds.height
        guard area > 0 else { return 0 }
        let visible = visiblePortion(of: view)
        return (visible.width * visible.height) / area
    }

    /// How much of a label must be in the bitmap before its spread is meaningful.
    /// A label is either wholly inside the transcript's clip view or straddling its
    /// edge, so this only has to separate "essentially all of it" from "a sliver".
    static let minimumVisibleTextFraction = 0.8

    /// Only views the bitmap actually contains a full render of. A transcript card
    /// scrolled past the clip view's bottom edge is not in the bitmap at all, so
    /// sampling its rect would read whatever else was drawn there and report a flat
    /// rect — a coordinate artefact, not a bug. `runPixelChecks` asserts a floor on
    /// how many views survive this filter, so it cannot go vacuous.
    private static func isFullyRendered(_ view: NSView) -> Bool {
        guard isPartlyRendered(view) else { return false }
        let visible = visiblePortion(of: view)
        return abs(visible.width - view.bounds.width) < 0.5
            && abs(visible.height - view.bounds.height) < 0.5
    }

    /// Anything of this view reaches the bitmap at all. Distinct from
    /// `isFullyRendered` because the transcript's document stack is *always* taller
    /// than its clip view — it is only partly rendered by design, while the cards
    /// inside it are fully rendered and are the things worth measuring.
    private static func isPartlyRendered(_ view: NSView) -> Bool {
        !view.isHidden && view.alphaValue > 0.01 && Double(view.layer?.opacity ?? 1) > 0.01
            && view.bounds.width > 0 && view.bounds.height > 0
            && !visiblePortion(of: view).isEmpty
    }

    /// Depth-first over every view with anything in the bitmap; a view with nothing
    /// in it stops the descent, because its children are equally absent. Deciding
    /// which probe a view is eligible for is the caller's, per probe: text needs
    /// `renderedFraction`, a border needs all four edges.
    private static func walk(_ root: NSView, _ body: (NSView) throws -> Void) throws {
        guard isPartlyRendered(root) else { return }
        try body(root)
        for subview in root.subviews { try walk(subview, body) }
    }

    // MARK: - Self-check

    /// A deliberately asymmetric patch: mirrored vertically it would land entirely
    /// outside itself, so a wrong flip cannot pass the coordinate check.
    static let fixtureSize = NSSize(width: 240, height: 140)
    static let fixturePatchFrame = NSRect(x: 30, y: 18, width: 72, height: 26)

    /// Backdrop and patch colours are far apart in luminance (0.0 vs 0.285) so the
    /// landing assertion is unambiguous.
    private static let fixtureBackdrop = NSColor(red: 0, green: 0, blue: 0, alpha: 1)
    private static let fixturePatchColor = NSColor(red: 1, green: 0, blue: 1, alpha: 1)

    /// `nil` label/border colours mean "correct"; passing a colour equal to the
    /// fill is how the two negative witnesses are built in-process.
    static func makeFixture(labelColor: NSColor? = nil, borderColor: NSColor? = nil) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: fixtureSize))
        root.wantsLayer = true
        root.layer?.backgroundColor = fixtureBackdrop.cgColor

        let patch = NSView(frame: fixturePatchFrame)
        patch.wantsLayer = true
        patch.layer?.backgroundColor = fixturePatchColor.cgColor
        patch.identifier = NSUserInterfaceItemIdentifier("pixelProbe.patch")
        root.addSubview(patch)

        let fill = NSColor(red: 0.13, green: 0.15, blue: 0.18, alpha: 1)
        let card = NSView(frame: NSRect(x: 30, y: 70, width: 160, height: 48))
        card.wantsLayer = true
        card.layer?.backgroundColor = fill.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = (borderColor ?? NSColor(white: 1, alpha: 0.14)).cgColor
        card.identifier = NSUserInterfaceItemIdentifier("pixelProbe.card")

        let label = NSTextField(labelWithString: "Legible fixture text")
        label.font = .systemFont(ofSize: 12)
        label.textColor = labelColor ?? NSColor(white: 1, alpha: 0.85)
        label.frame = NSRect(x: 10, y: 14, width: 140, height: 18)
        label.identifier = NSUserInterfaceItemIdentifier("pixelProbe.label")
        card.addSubview(label)
        root.addSubview(card)
        return root
    }

    /// Both probes over the managed-agent tile (transcript cards + tile chrome) in
    /// both appearances, on top of a coordinate-landing check and two in-process
    /// negative witnesses.
    static func runPixelChecks() throws {
        _ = NSApplication.shared
        // Production pins the app appearance at launch (`ContinuumApp`), so pinning
        // it dark here keeps the `.aqua` pass honest.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        try runCoordinateLandingCheck()
        try runNegativeWitnesses()

        let entries = LabCatalog.entries(env: LabEnvironment(ghostty: nil, browserEngine: nil))
        guard let entry = entries.first(where: { $0.id == "tiles.managedAgent" }),
              case let .staticCard(_, make) = entry.content else {
            throw fail("missing tiles.managedAgent card")
        }

        var textProbes = 0
        var borderProbes = 0
        var cardBorderProbes = 0
        var skippedText = 0
        var skippedBorders = 0
        var worstText = (spread: Double.infinity, key: "")
        var worstBorder = (delta: Double.infinity, key: "")
        // Per appearance, not totalled: an aggregate floor is satisfied by one
        // appearance carrying the whole run while the other silently probes nothing.
        let minimumCardBordersPerAppearance = 3
        let minimumTextRectsPerAppearance = 8

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let size = NSSize(width: 640, height: 560)
            let label = "managedAgent.\(appearanceName.rawValue)"
            let probe = try UIProbe.render(
                UIProbe.Spec(id: label, size: size, appearance: appearanceName), make: make
            )
            guard let tile = probe.view as? ManagedAgentTileNSView else {
                throw fail("\(label): tiles.managedAgent did not vend ManagedAgentTileNSView")
            }
            // A blank render would make every rect below flat for one reason, not
            // many: say so once, in the vocabulary the Tier-1 gate already uses.
            let metrics = VisualSnapshot.metrics(of: probe.hostRep)
            guard !metrics.isBlank else {
                throw fail("\(label): probe bitmap is blank (\(metrics.width)x\(metrics.height), \(metrics.distinctSampledColors) colours)")
            }

            var appearanceTextProbes = 0
            var appearanceCardBorders = 0
            try walk(tile) { view in
                let key = "\(label) \(describe(view))"
                if drawnText(of: view) != nil {
                    if renderedFraction(of: view) >= minimumVisibleTextFraction {
                        let spread = try expectLegibleText(in: view, probe: probe, label: key)
                        if spread < worstText.spread { worstText = (spread, key) }
                        textProbes += 1
                        appearanceTextProbes += 1
                    } else {
                        skippedText += 1
                    }
                }
                if let layer = view.layer, layer.borderWidth > 0, layer.borderColor != nil {
                    if isFullyRendered(view) {
                        let delta = try expectVisibleBorder(of: view, probe: probe, label: key)
                        if delta < worstBorder.delta { worstBorder = (delta, key) }
                        borderProbes += 1
                        if view is TranscriptCardView {
                            cardBorderProbes += 1
                            appearanceCardBorders += 1
                        }
                    } else {
                        skippedBorders += 1
                    }
                }
            }

            // Floors, so the clipped-view and alpha filters can never quietly empty
            // the run: this appearance must have contributed real coverage.
            guard appearanceCardBorders >= minimumCardBordersPerAppearance else {
                throw fail("\(label): only \(appearanceCardBorders) transcript-card border(s) probed, needs >= \(minimumCardBordersPerAppearance)")
            }
            guard appearanceTextProbes >= minimumTextRectsPerAppearance else {
                throw fail("\(label): only \(appearanceTextProbes) text rect(s) probed, needs >= \(minimumTextRectsPerAppearance)")
            }
        }

        guard NSApp.appearance?.name == .darkAqua else {
            throw fail("probing mutated NSApp.appearance to '\(NSApp.appearance?.name.rawValue ?? "nil")'")
        }
        // Skips are printed, never silent: a jump in either number means the probe
        // stopped covering something it used to cover.
        print(String(
            format: "UIProbePixels: %d text rects + %d borders (%d transcript cards) gated in both appearances; %d clipped text rects and %d clipped borders skipped; worst text spread %.3f (%@); worst border delta %.3f (%@)",
            textProbes, borderProbes, cardBorderProbes, skippedText, skippedBorders,
            worstText.spread, worstText.key.isEmpty ? "none" : worstText.key,
            worstBorder.delta, worstBorder.key.isEmpty ? "none" : worstBorder.key
        ))
    }

    /// The sampled rect must actually land on the view it was computed from. Without
    /// this, a flipped or misscaled conversion would sample the wrong region and
    /// every assertion above it would be measuring something else.
    private static func runCoordinateLandingCheck() throws {
        let probe = try UIProbe.render(
            UIProbe.Spec(id: "pixelProbe.fixture", size: fixtureSize, appearance: .darkAqua),
            make: { makeFixture() }
        )
        guard let patch = probe.view.descendant(withIdentifier: "pixelProbe.patch") else {
            throw fail("fixture has no patch view")
        }
        let rect = try bitmapRect(of: patch, rect: patch.bounds, in: probe)
        let scale = Double(probe.hostRep.pixelsWide) / probe.host.bounds.width
        let expected = PixelRect(
            x: Int((fixturePatchFrame.minX * scale).rounded()),
            y: Int(((fixtureSize.height - fixturePatchFrame.maxY) * scale).rounded()),
            width: Int((fixturePatchFrame.width * scale).rounded()),
            height: Int((fixturePatchFrame.height * scale).rounded())
        )
        guard rect == expected else {
            throw fail("patch maps to \(rect), expected \(expected) at scale \(scale)")
        }

        // Asserted **relatively**: the patch region must be uniform and clearly
        // unlike the backdrop. Not against the patch colour's own luminance —
        // AppKit renders through the display's colour space, so a pixel read back
        // as deviceRGB does not carry the components the colour was built with
        // (measured: sRGB magenta reads back at luminance 0.521, not 0.285). A
        // uniform-and-distinct assertion needs no colour-space bookkeeping and
        // still fails on any misplaced rect.
        var patchMin = Double.infinity
        var patchMax = -Double.infinity
        var patchSum = 0.0
        var patchCount = 0
        // Inset by one pixel: the boundary pixel is antialiased against the backdrop.
        for y in (rect.y + 1)..<(rect.y + rect.height - 1) {
            for x in (rect.x + 1)..<(rect.x + rect.width - 1) {
                guard let value = luminance(probe.hostRep, x: x, y: y) else {
                    throw fail("could not read fixture pixel (\(x),\(y))")
                }
                patchMin = min(patchMin, value)
                patchMax = max(patchMax, value)
                patchSum += value
                patchCount += 1
            }
        }
        guard patchCount > 0 else { throw fail("patch rect sampled no pixels") }
        guard patchMax - patchMin < 0.01 else {
            throw fail(String(
                format: "patch rect is not uniform — luminance %.3f…%.3f, so it does not land on the patch alone",
                patchMin, patchMax
            ))
        }
        let patchLuminance = patchSum / Double(patchCount)
        guard let backdrop = luminance(probe.hostRep, x: 2, y: 2) else {
            throw fail("could not read the fixture backdrop")
        }
        guard abs(patchLuminance - backdrop) > 0.2 else {
            throw fail(String(
                format: "patch (%.3f) is not distinct from the backdrop (%.3f) — the landing check cannot witness a misplaced rect",
                patchLuminance, backdrop
            ))
        }
        // And the mirrored rect must NOT be the patch, so a correct-by-accident
        // symmetric conversion cannot pass.
        let mirroredY = probe.hostRep.pixelsHigh - rect.y - rect.height
        var mirroredIsPatch = true
        for x in (rect.x + 1)..<(rect.x + rect.width - 1) {
            guard let value = luminance(probe.hostRep, x: x, y: mirroredY + rect.height / 2) else { continue }
            if abs(value - patchLuminance) >= 0.01 { mirroredIsPatch = false; break }
        }
        guard !mirroredIsPatch else {
            throw fail("the vertically mirrored rect is also the patch — the fixture cannot witness a flip error")
        }
    }

    /// The two failures the packet names, asserted in-process rather than left as
    /// commented-out edits: a label drawn in its background colour, and a border
    /// drawn in its fill colour.
    private static func runNegativeWitnesses() throws {
        let fill = NSColor(red: 0.13, green: 0.15, blue: 0.18, alpha: 1)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let invisibleText = try UIProbe.render(
                UIProbe.Spec(id: "pixelProbe.invisibleText", size: fixtureSize, appearance: appearanceName),
                make: { makeFixture(labelColor: fill) }
            )
            guard let label = invisibleText.view.descendant(withIdentifier: "pixelProbe.label") else {
                throw fail("fixture has no label view")
            }
            do {
                let spread = try expectLegibleText(in: label, probe: invisibleText, label: "witness.invisibleText")
                throw fail(String(
                    format: "text drawn in its own background colour passed with spread %.3f — the flatness gate cannot fire",
                    spread
                ))
            } catch let error as PixelError where error.message.contains("text rect is flat") {
                // Expected.
            }

            let invisibleBorder = try UIProbe.render(
                UIProbe.Spec(id: "pixelProbe.invisibleBorder", size: fixtureSize, appearance: appearanceName),
                make: { makeFixture(borderColor: fill) }
            )
            guard let card = invisibleBorder.view.descendant(withIdentifier: "pixelProbe.card") else {
                throw fail("fixture has no card view")
            }
            do {
                let delta = try expectVisibleBorder(of: card, probe: invisibleBorder, label: "witness.invisibleBorder")
                throw fail(String(
                    format: "border drawn in its own fill colour passed with delta %.3f — the border gate cannot fire",
                    delta
                ))
            } catch let error as PixelError where error.message.contains("border is invisible") {
                // Expected.
            }

            // …and the same fixture with correct colours must PASS, or the two
            // witnesses above would be satisfied by a gate that rejects everything.
            let good = try UIProbe.render(
                UIProbe.Spec(id: "pixelProbe.legible", size: fixtureSize, appearance: appearanceName),
                make: { makeFixture() }
            )
            guard let goodLabel = good.view.descendant(withIdentifier: "pixelProbe.label"),
                  let goodCard = good.view.descendant(withIdentifier: "pixelProbe.card") else {
                throw fail("fixture is missing its label or card")
            }
            try expectLegibleText(in: goodLabel, probe: good, label: "witness.legibleText")
            try expectVisibleBorder(of: goodCard, probe: good, label: "witness.visibleBorder")
        }
    }

    // MARK: - Regression witnesses over production code
    //
    // The in-process witnesses above prove the probes fire on a fixture. These two
    // edits prove they fire on the real tile; each was applied, run, and observed
    // RED, and the quoted text is the real output.
    //
    // 1 · Invisible transcript text. In `TranscriptCardViews.swift`, paint the body
    //     label in the card's own fill:
    //         bodyLabel.textColor = Self.background(for: card.kind)
    //     → "managedAgent.NSAppearanceNameAqua NSTextField: text rect is flat —
    //        luminance spread 0.000 over 23424 px, needs >= 0.050 (min 0.197,
    //        max 0.197)"
    //
    // 2 · Invisible card border. In the same file:
    //         layer?.borderColor = Self.background(for: card.kind).cgColor
    //     → "managedAgent.NSAppearanceNameAqua
    //        TranscriptCardView#managedAgent.card.assistant-1: border is invisible —
    //        luminance delta 0.000 (left 0.000, top 0.000), needs >= 0.030"
}
