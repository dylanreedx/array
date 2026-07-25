import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Contrast assertions read off a `UIProbe`-rendered view tree, in **both**
/// appearances.
///
/// The bug this exists for: the owner's Mac resolves light appearance, every
/// custom surface here is a hardcoded dark fill, and every label was a dynamic
/// semantic colour. `labelColor` measures black@85% in Aqua and white@85% in
/// DarkAqua, so on a light Mac the chrome painted black text on a dark fill —
/// unreadable, and invisible to every gate that existed. That shipped for weeks.
///
/// Deliberately read **from the view tree, not from a token table**: a view that
/// bypasses the design tokens entirely still gets gated. The ratio itself comes
/// from `WCAGContrast` (Core), so the maths is the same one the StatusChip
/// presentation model is already gated on.
@MainActor
enum UIProbeContrast {
    struct ContrastError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func fail(_ message: String) -> ContrastError { ContrastError(message: message) }

    /// WCAG 2.1 AA: 4.5:1 for body text, 3:1 for non-text (borders, glyphs).
    static let textMinimumRatio = 4.5
    static let nonTextMinimumRatio = 3.0

    /// Explicit exemptions, keyed `"<entry id> <view>"` — the same key the
    /// failure message prints, so an exemption is always copy-pasteable from a
    /// real failure and never a guess.
    ///
    /// An entry here is a statement that the *pair* is correct and the ratio is
    /// not the right question for it. It is NOT the way to silence a failure: if
    /// text is unreadable, the colour is wrong.
    ///
    /// Empty, and staying empty: 177 of 446 pairs currently fail, and the packet
    /// forbids exempting them. Those are real unreadable pairs awaiting the
    /// light+dark tokens — see `docs/38-tickets/90-agent-ux/P0.4-FINDINGS.md`,
    /// which is also why this gate has no `run-matrix.sh` leg yet.
    static let allowlist: [String: String] = [:]

    // MARK: - Colour plumbing

    /// sRGB with straight alpha. AppKit hands back four different colour
    /// representations here (`CGColor` off a layer, `NSColor` off a text field,
    /// dynamic catalog colours, pattern colours), so everything is funnelled
    /// through one struct before any maths happens.
    private struct RGBA {
        var r: Double
        var g: Double
        var b: Double
        var a: Double
    }

    /// `nil` for anything with no sRGB representation — pattern and image
    /// colours. The caller skips those rather than guessing a luminance.
    private static func rgba(_ color: NSColor) -> RGBA? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return RGBA(
            r: srgb.redComponent, g: srgb.greenComponent, b: srgb.blueComponent,
            a: srgb.alphaComponent
        )
    }

    private static func rgba(_ color: CGColor) -> RGBA? {
        guard let ns = NSColor(cgColor: color) else { return nil }
        return rgba(ns)
    }

    /// Straight-alpha source-over. This is the whole reason a token table could
    /// not answer this question: `labelColor` is 85% opaque, so its *effective*
    /// colour depends on the fill beneath it.
    private static func composite(_ fg: RGBA, over bg: RGBA) -> RGBA {
        RGBA(
            r: fg.r * fg.a + bg.r * (1 - fg.a),
            g: fg.g * fg.a + bg.g * (1 - fg.a),
            b: fg.b * fg.a + bg.b * (1 - fg.a),
            a: 1
        )
    }

    private static func chip(_ color: RGBA) -> ChipColor {
        ChipColor(r: color.r, g: color.g, b: color.b)
    }

    // MARK: - Measurement

    struct Measurement {
        let key: String
        /// `"text"`, `"border"` or `"glyph"` — which threshold applies.
        let kind: String
        let ratio: Double
        let minimum: Double
        let foreground: String
        let background: String
    }

    private static func describe(_ view: NSView) -> String {
        let name = String(describing: type(of: view))
        if let id = view.identifier?.rawValue { return "\(name)#\(id)" }
        return name
    }

    private static func hex(_ color: RGBA) -> String {
        String(
            format: "#%02X%02X%02X@%.2f",
            Int((min(max(color.r, 0), 1) * 255).rounded()),
            Int((min(max(color.g, 0), 1) * 255).rounded()),
            Int((min(max(color.b, 0), 1) * 255).rounded()),
            color.a
        )
    }

    /// Every text, border and glyph pair in `probe`, measured in `probe`'s appearance.
    ///
    /// The walk starts at `probe.host`, whose opaque `windowBackgroundColor`
    /// layer (set by `UIProbe.render`) is the base every translucent fill above
    /// it composites onto — so the background is always a fully resolved opaque
    /// colour and no case has to invent one.
    ///
    /// Runs inside the probe's appearance, with `NSApp.appearance` pinned to it:
    /// an `NSTextField.textColor` is a dynamic catalog colour, and
    /// `usingColorSpace` resolves it against `NSAppearance.current`. Reading it
    /// after `render` returned would measure the *app's* appearance — which is
    /// exactly the class of bug this gate is for.
    static func measurements(of probe: UIProbe.Probed) throws -> [Measurement] {
        guard let baseLayerColor = probe.host.layer?.backgroundColor,
              let base = rgba(baseLayerColor), base.a >= 0.999 else {
            throw fail("\(probe.spec.id): probe host has no opaque backdrop to measure against")
        }

        var collected: [Measurement] = []
        var thrown: Error?
        let appAppearance = NSApp?.appearance
        NSApp?.appearance = probe.appearance
        defer { NSApp?.appearance = appAppearance }
        probe.appearance.performAsCurrentDrawingAppearance {
            do {
                try visit(probe.host, background: base, prefix: probe.spec.id, alpha: 1, into: &collected)
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
        return collected
    }

    /// Depth-first, carrying the resolved opaque background down.
    ///
    /// `alpha` is the product of every ancestor's `alphaValue` and `layer.opacity`.
    /// It is applied to **fills as well as** text and borders: a faded view fades
    /// as a group, so its background weakens toward the backdrop by exactly as
    /// much as its glyphs do, and fading only the foreground would understate the
    /// ratio. (Per-contribution fading is a first-order model of AppKit's
    /// flatten-then-fade group opacity; the two agree exactly at alpha 0 and 1,
    /// which is every static case in the lab — `ApprovalDockView` parks at 0 when
    /// there is nothing to approve, and everything else sits at 1.)
    private static func visit(
        _ view: NSView, background: RGBA, prefix: String, alpha: Double,
        into collected: inout [Measurement]
    ) throws {
        let effectiveAlpha = alpha * Double(view.alphaValue) * Double(view.layer?.opacity ?? 1)
        // Invisible chrome is not a contrast bug. Zero-size views are the
        // geometry gate's business (`UIProbeGeometry.expectNoZeroSizeViews`);
        // asserting on them here would report a colour problem for a layout one.
        guard !view.isHidden, effectiveAlpha > 0.01,
              view.bounds.width > 0, view.bounds.height > 0 else { return }

        let key = "\(prefix) \(describe(view))"
        var background = background

        // The view's own fill becomes the background for its own text, its own
        // border, and its whole subtree.
        for fill in [view.layer?.backgroundColor.flatMap(rgba), ownFill(of: view).flatMap(rgba)] {
            guard var fill, fill.a > 0.001 else { continue }
            fill.a *= effectiveAlpha
            background = composite(fill, over: background)
        }

        if let borderColor = view.layer?.borderColor, (view.layer?.borderWidth ?? 0) > 0,
           var border = rgba(borderColor), border.a > 0.001 {
            border.a *= effectiveAlpha
            collected.append(measure(
                key: key, kind: "border", minimum: nonTextMinimumRatio,
                foreground: border, background: background
            ))
        }

        if var foreground = textColor(of: view).flatMap(rgba) {
            foreground.a *= effectiveAlpha
            collected.append(measure(
                key: key, kind: "text", minimum: textMinimumRatio,
                foreground: foreground, background: background
            ))
        }

        // Glyph-only chrome at the non-text threshold, and only where the tint is
        // set explicitly: AppKit does not expose the colour it defaults a template
        // image to, and inventing one would be a guess.
        if var glyph = glyphTint(of: view).flatMap(rgba) {
            glyph.a *= effectiveAlpha
            collected.append(measure(
                key: key, kind: "glyph", minimum: nonTextMinimumRatio,
                foreground: glyph, background: background
            ))
        }

        for subview in view.subviews {
            try visit(
                subview, background: background, prefix: prefix, alpha: effectiveAlpha,
                into: &collected
            )
        }
    }

    private static func measure(
        key: String, kind: String, minimum: Double, foreground: RGBA, background: RGBA
    ) -> Measurement {
        let resolved = composite(foreground, over: background)
        return Measurement(
            key: key, kind: kind,
            ratio: WCAGContrast.ratio(chip(resolved), chip(background)),
            minimum: minimum,
            foreground: hex(resolved), background: hex(background)
        )
    }

    /// A fill this view paints itself, outside its layer. Every one of these is a
    /// real AppKit property, not an inference: the tile text views set
    /// `backgroundColor` directly (`NoteTileNSView`, `DiffReviewTileNSView`), and
    /// several scroll views switch theirs off (`drawsBackground = false`), which
    /// must read as transparent rather than as an opaque fill.
    ///
    /// Known limit: a background painted in a custom `draw(_:)` override cannot be
    /// read off any property, so this walk measures such a view's text against the
    /// nearest fill it *can* read. Pixel-level sampling is `P0.5-pixel-probes`.
    private static func ownFill(of view: NSView) -> NSColor? {
        if let field = view as? NSTextField { return field.drawsBackground ? field.backgroundColor : nil }
        if let textView = view as? NSTextView { return textView.drawsBackground ? textView.backgroundColor : nil }
        if let scrollView = view as? NSScrollView { return scrollView.drawsBackground ? scrollView.backgroundColor : nil }
        if let tableView = view as? NSTableView { return tableView.backgroundColor }
        return nil
    }

    /// An explicitly tinted glyph, or `nil`. Guarded on there being an image at
    /// all, so an untinted or image-less control is not measured.
    private static func glyphTint(of view: NSView) -> NSColor? {
        if let imageView = view as? NSImageView {
            return imageView.image == nil ? nil : imageView.contentTintColor
        }
        if let button = view as? NSButton {
            return button.image == nil ? nil : button.contentTintColor
        }
        return nil
    }

    /// The colour this view actually paints glyphs in, or `nil` if it paints no
    /// glyphs. Empty and whitespace-only fields are `nil`: there is nothing on
    /// screen to be unreadable, and a placeholder is drawn in a colour the field
    /// does not expose.
    private static func textColor(of view: NSView) -> NSColor? {
        if let field = view as? NSTextField {
            guard !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return field.textColor ?? .labelColor
        }
        if let textView = view as? NSTextView {
            guard !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return textView.textColor ?? .labelColor
        }
        return nil
    }

    // MARK: - Self-check

    static func runContrastChecks() throws {
        _ = NSApplication.shared
        // Production pins the app appearance at launch (`ContinuumApp`). Pinning
        // it dark here means a `.aqua` pass can only be honest if the probe and
        // the measurement both really move the appearance.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let entries = LabCatalog.entries(env: LabEnvironment(ghostty: nil, browserEngine: nil))
        var failures: [String] = []
        var measured = 0
        var exempted = 0
        var worstText = (ratio: Double.infinity, key: "")
        var worstBorder = (ratio: Double.infinity, key: "")

        for entry in entries {
            guard case let .staticCard(preferredSize, make) = entry.content else { continue }
            let size = preferredSize ?? NSSize(width: 560, height: 640)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let probe = try UIProbe.render(
                    UIProbe.Spec(id: entry.id, size: size, appearance: name), make: make
                )
                for measurement in try measurements(of: probe) {
                    if allowlist[measurement.key] != nil {
                        exempted += 1
                        continue
                    }
                    measured += 1
                    if measurement.kind == "text" {
                        if measurement.ratio < worstText.ratio {
                            worstText = (measurement.ratio, measurement.key)
                        }
                    } else if measurement.ratio < worstBorder.ratio {
                        worstBorder = (measurement.ratio, measurement.key)
                    }
                    guard measurement.ratio < measurement.minimum else { continue }
                    failures.append(String(
                        format: "%@ [%@ · %@]: %.2f:1, needs >= %.1f:1 (fg %@ on bg %@)",
                        measurement.key, name.rawValue, measurement.kind,
                        measurement.ratio, measurement.minimum,
                        measurement.foreground, measurement.background
                    ))
                }
            }
        }

        guard measured > 0 else { throw fail("no text or border pairs were measured") }
        guard failures.isEmpty else {
            throw fail(
                "\(failures.count) unreadable pair(s) of \(measured) measured:\n  - "
                    + failures.joined(separator: "\n  - ")
            )
        }
        // The probe must not leak its appearance onto the app.
        guard NSApp.appearance?.name == .darkAqua else {
            throw fail("measuring mutated NSApp.appearance to '\(NSApp.appearance?.name.rawValue ?? "nil")'")
        }
        print(String(
            format: "UIProbeContrast: %d pairs gated in both appearances (%d exempt); worst text %.2f:1 (%@); worst non-text %.2f:1 (%@)",
            measured, exempted,
            worstText.ratio, worstText.key.isEmpty ? "none" : worstText.key,
            worstBorder.ratio, worstBorder.key.isEmpty ? "none" : worstBorder.key
        ))
    }
}
