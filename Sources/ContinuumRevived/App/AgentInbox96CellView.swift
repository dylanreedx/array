import AppKit
import ContinuumRevivedAgentUI
import Foundation

// Program 96 — the redesigned agent row, as a REAL cell.
//
// Everything before this was a painting: `SidebarDensityProposalView` draws the
// anatomy into a bitmap so it can be reviewed, and you cannot click it, hover it,
// scroll it or select in it. This is the same anatomy as an `AgentInboxRowCell`,
// so the SHIPPED `AgentInboxView` renders it — with its real scrolling, hover,
// multi-selection, context menus, disclosure triangles, jump pills, rename and
// accessibility, none of which is reimplemented here.
//
// **It is injected, never defaulted.** `AgentInboxView.cardStyleOverride` is nil
// everywhere except the Component Lab section that sets it, so production and
// every queue-94 gate see exactly the view they saw before. Making this the
// default is Phase 1–3 work and needs the S0 ruling first: the pitch below is
// still a proposal.
//
// WHAT IS SHARED, AND WHY IT MATTERS: the ink alignment and the brand marks live
// here, and `SidebarScreenshotChecks` calls into them. So the review images, this
// cell, and the alignment witness are all one implementation — a witness that
// measured a copy would prove nothing about what you are clicking on.

// MARK: - Ink-aligned symbols

/// Placing a glyph by its INK rather than by its bounding box.
///
/// SF Symbols do not share an optical size. Measured across the status set:
/// `hand.raised.fill` covers 68% of its box horizontally where the circles cover
/// 86%, so centring them in one slot scatters their left edges across 1.44 pt of
/// a 16 pt slot — a ragged margin down a leading column, which is exactly what
/// Dylan reported seeing.
///
/// Their LARGEST dimensions already agree to within 5%, which is why the first
/// attempt at this — normalising the largest dimension — corrected nothing and
/// was caught by its own check. Width is the axis that moves.
@MainActor
enum InkAlignedSymbol {
    /// How much of the slot the ink fills.
    static let inkTargetFraction: CGFloat = 0.82

    /// Which edge to line up. A leading column aligns left edges; a glyph sitting
    /// beside its own word centres.
    enum Alignment { case centred, leadingEdge }

    private static var imageCache: [String: NSImage?] = [:]
    private static var inkCache: [String: NSRect?] = [:]

    /// The symbol at a size large enough that the ink measurement is not itself
    /// quantised by the render.
    static func image(_ name: String) -> NSImage? {
        if let cached = imageCache[name] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        imageCache[name] = image
        return image
    }

    /// The glyph's ink extent as a fraction of a unit square, measured top-down so
    /// it composes with `respectFlipped:` drawing without a second flip.
    static func ink(_ name: String) -> NSRect? {
        if let cached = inkCache[name] { return cached }
        let measured = image(name).flatMap { measureInk(of: $0) }
        inkCache[name] = measured
        return measured
    }

    /// Where to draw the unit-square glyph image so its ink lands correctly on
    /// `slot` at a common extent. Pure arithmetic, so a gate can drive it directly.
    static func rect(slot: NSRect, ink: NSRect, alignment: Alignment = .centred) -> NSRect {
        let target = slot.width * inkTargetFraction
        let side = target / max(max(ink.width, ink.height), 0.0001)
        let x = alignment == .leadingEdge
            ? slot.minX - (ink.minX * side)
            : slot.midX - (ink.midX * side)
        return NSRect(x: x, y: slot.midY - (ink.midY * side), width: side, height: side)
    }

    /// Render into a square bitmap and find the alpha extent.
    static func measureInk(of image: NSImage, side: Int = 128) -> NSRect? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let box = NSRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // A template image draws in the current fill colour; force an opaque one so
        // the scan measures the glyph and not an antialiased ghost.
        NSColor.black.setFill()
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return inkBounds(of: rep)
    }

    /// Alpha extent of a bitmap, normalised to its own size, measured top-down.
    static func inkBounds(of rep: NSBitmapImageRep, threshold: Int = 24) -> NSRect? {
        guard let data = rep.bitmapData else { return nil }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let rowBytes = rep.bytesPerRow, pixelBytes = rep.bitsPerPixel / 8
        let alphaOffset = pixelBytes - 1
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * rowBytes
            for x in 0..<width where Int(data[row + x * pixelBytes + alphaOffset]) > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return NSRect(
            x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height))
    }

    /// Draw `name` so its ink lands on `slot`, in `colour`.
    static func draw(
        _ name: String, in slot: NSRect, colour: NSColor, alignment: Alignment,
        flipped: Bool
    ) {
        guard let image = image(name), let ink = ink(name) else { return }
        drawTinted(image, in: rect(slot: slot, ink: ink, alignment: alignment),
                   colour: colour, flipped: flipped)
    }

    /// Draw an image flattened to one colour.
    ///
    /// A translucent `sourceAtop` fill BLENDS with the source's own colour instead
    /// of replacing it — Anthropic's `#D97757` under a 72%-black tint came out
    /// maroon rather than grey. Flatten with an opaque fill and apply the opacity
    /// at draw time, so a mark's own palette can never leak through. The tinted
    /// copy is built at the DESTINATION size: the vendor SVGs report up to 1024 pt
    /// and the slot is 14.
    static func drawTinted(
        _ image: NSImage, in rect: NSRect, colour: NSColor?, flipped: Bool
    ) {
        let drawable: NSImage
        let fraction = colour?.alphaComponent ?? 1
        if let colour = colour?.withAlphaComponent(1) {
            let scale: CGFloat = 3
            let size = NSSize(
                width: max(1, rect.width * scale), height: max(1, rect.height * scale))
            let copy = NSImage(size: size)
            copy.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: size))
            colour.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            copy.unlockFocus()
            drawable = copy
        } else {
            drawable = image
        }
        drawable.draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: fraction,
            respectFlipped: flipped, hints: nil)
    }
}

// MARK: - Brand marks

/// Vendor marks, loaded from the ticket directory by repo-relative path.
///
/// **DESIGN-TIME ONLY. This cannot ship.** Nothing here is bundled into the
/// `.app`, so a released build would find no file and draw the name fallback for
/// every provider. The real pipeline — a resource catalogue, `Package.swift`
/// declarations, `make-app-bundle.sh` handling and §5.5's offline bundle witness —
/// is P3.1, and so is the per-vendor trademark review that has to happen before
/// any of these are distributed. §10 forbids fetching a logo at runtime and
/// nothing here fetches.
@MainActor
enum BrandMark96 {
    private static var cache: [String: NSImage?] = [:]

    /// The mark for a model id, or nil when Array has no asset for its vendor.
    ///
    /// **Keyed off the PROVIDER, not the model's spelling**, and that distinction
    /// cost the first render of this cell. The S0 mock used display names —
    /// `GPT-5.6 Sol`, `Opus` — so a `hasPrefix("GPT")` test matched. Real ids are
    /// fully qualified `provider/model` (`openai-codex/gpt-5.6-sol`,
    /// `anthropic/claude-opus-...`), exactly as non-negotiable #5 requires, so that
    /// test matched nothing and every production row fell through to printing its
    /// whole model id. One more way the mock flattered itself.
    ///
    /// Still a mock's affordance, though: a row's provider should come off the
    /// agent record, not be parsed out of a string. P3.1.
    static func mark(forModel model: String) -> NSImage? {
        let provider = model.split(separator: "/").first.map(String.init)?.lowercased()
            ?? model.lowercased()
        let key: String
        switch provider {
        case let p where p.hasPrefix("openai"): key = "openai-light"   // incl. openai-codex
        case let p where p.hasPrefix("anthropic"), let p where p.hasPrefix("claude"):
            key = "anthropic"
        case let p where p.hasPrefix("xai"), let p where p.hasPrefix("grok"):
            key = "xai-light"
        case let p where p.hasPrefix("google"), let p where p.hasPrefix("gemini"):
            key = "gemini"
        default: return nil
        }
        return load(key)
    }

    /// What to print when there is no mark. The model's own trailing segment, not
    /// the fully-qualified id: `mistral-large-3` says what is running, where
    /// `mistralai/mistral-large-3` spends the whole band saying it twice.
    ///
    /// The exact id stays in the tooltip and the accessibility label either way —
    /// §4.3 requires that at every step of the sacrifice ladder, and a partial id
    /// is exactly what non-negotiable #5 says fuzzy-matches the wrong model.
    static func fallbackName(forModel model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    static func load(_ key: String) -> NSImage? {
        if let cached = cache[key] { return cached }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // App
            .deletingLastPathComponent()   // ContinuumRevived
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(
                "docs/38-tickets/96-agent-sidebar-product-redesign/brand-marks/\(key).svg")
        let image = NSImage(contentsOf: url)
        cache[key] = image
        return image
    }
}

// MARK: - The cell

/// The program-96 card row.
///
/// Three bands at a fixed pitch, a leading attention column, and a provider mark
/// where the model name used to be. Laid out in `layout()` rather than with Auto
/// Layout: the bands are fixed heights by design, so the arithmetic here is the
/// same arithmetic `SidebarDensityProposal` reports and the two cannot drift.
@MainActor
final class AgentInbox96CellView: NSTableCellView, AgentInboxRowCell {
    /// Pitch and anatomy for THIS cell, handed in by whoever built it, so the Lab
    /// can retune live without a static anyone else can see.
    let proposal: SidebarDensityProposal
    let anatomy: SidebarRowAnatomy

    private let card = AgentInboxCardView()
    private let jumpHint = InboxJumpHintView()
    private let disclosureButton = InboxDisclosureButton()
    var onToggleDisclosure: (() -> Void)?

    private let placementLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    /// The model NAME, drawn only when there is no mark for its vendor. §4.5
    /// specifies a two-character badge here; `GE` for Gemini was unreadable to the
    /// person who commissioned it, so the fallback is the name. Recorded as a
    /// proposed §4.5 amendment in `brand-marks/PROVENANCE.md`.
    private let modelLabel = NSTextField(labelWithString: "")

    /// Painted, not sub-viewed: the status glyph, the branch glyph and the
    /// provider mark are three small images whose placement is arithmetic. One
    /// `NSImageView` each would be three more views per row to lay out and recycle,
    /// and `docs/internals/performance.md` is explicit that a view per content item
    /// is how the Markdown tile froze the app.
    private let decorations = Decorations()

    /// The app's own throbber, added only while a row is working and removed the
    /// moment it is not — a `CAAnimation` per row is the one thing here that costs
    /// something while idle.
    private var throbber: DualPlaneGyroTiltedThinkingIndicatorView?

    private var shown: (row: AgentInboxRow, emphasis: RowEmphasis, indent: Double,
                        disclosure: RowDisclosure, rollup: ChildRollup?,
                        isSelected: Bool)?
    private var layoutColumnWidth: Double?
    private var indent: Double = 0

    /// The row height this anatomy needs: the card, plus the gap that separates it
    /// from the next one. Every band is always drawn, which is the entire point of
    /// the redesign, so unlike the queue-94 row this does not vary with content.
    static func rowHeight(for proposal: SidebarDensityProposal) -> Double {
        Double(proposal.pitch)
    }

    init(proposal: SidebarDensityProposal, anatomy: SidebarRowAnatomy) {
        self.proposal = proposal
        self.anatomy = anatomy
        super.init(frame: NSRect(x: 0, y: 0, width: 280,
                                 height: Self.rowHeight(for: proposal)))
        wantsLayer = true

        addSubview(card)
        card.addSubview(decorations)

        placementLabel.font = .token(.caption)
        stateLabel.font = .token(.label)
        titleLabel.font = .token(.title)
        branchLabel.font = .token(.label)
        modelLabel.font = .token(.label)
        stateLabel.alignment = .right
        modelLabel.alignment = .right
        branchLabel.lineBreakMode = .byTruncatingMiddle
        for label in [placementLabel, stateLabel, titleLabel, branchLabel, modelLabel] {
            label.lineBreakMode = label === branchLabel ? .byTruncatingMiddle : .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            card.addSubview(label)
        }

        disclosureButton.target = self
        disclosureButton.action = #selector(disclosureClicked)
        disclosureButton.isHidden = true
        card.addSubview(disclosureButton)
        // An OVERLAY, never an arranged subview: a pill that joins the row's stack
        // pushes the status label out of the line. That regression has a name in
        // this codebase — holding ⌘ blanked out "Working".
        addSubview(jumpHint)

        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: Content

    func setLayoutWidth(_ width: Double) {
        layoutColumnWidth = width
        needsLayout = true
    }

    func apply(_ row: AgentInboxRow, emphasis: RowEmphasis, indent: Double,
               disclosure: RowDisclosure, rollup: ChildRollup?, isSelected: Bool,
               isInteracting: Bool, now: Date) {
        shown = (row, emphasis, indent, disclosure, rollup, isSelected)
        self.indent = indent
        card.isSelected = isSelected

        placementLabel.stringValue = row.projectName ?? ""
        titleLabel.stringValue = row.displayTitle
        branchLabel.stringValue = row.branch ?? ""

        // The state WORD and its time, in one string, exactly as the review images
        // read: `Done · 4m`. The elapsed half comes from the shipped formatter, not
        // a second one — `AgentInboxCellView.elapsedText` already decides what a
        // duration looks like on this surface.
        let word = Self.stateWord(row)
        let elapsed = AgentInboxCellView.elapsedText(row.elapsed)
        stateLabel.stringValue = [word, elapsed].compactMap { $0 }.joined(separator: " · ")
        stateLabel.isHidden = stateLabel.stringValue.isEmpty

        // Mark or name, never a cipher.
        let model = row.model ?? ""
        decorations.mark = model.isEmpty ? nil : BrandMark96.mark(forModel: model)
        let showsName = anatomy.showsModelText || (decorations.mark == nil && !model.isEmpty)
        modelLabel.stringValue = showsName ? BrandMark96.fallbackName(forModel: model) : ""
        modelLabel.isHidden = modelLabel.stringValue.isEmpty
        // The exact model id stays reachable when the row does not print it — §4.3
        // requires that of every step of the sacrifice ladder.
        modelLabel.toolTip = model.isEmpty ? nil : model
        decorations.toolTip = model.isEmpty ? nil : model

        decorations.statusSymbol = Self.attentionSymbol(row)
        decorations.isWorking = row.state == .working
        decorations.drawsBranchGlyph = !branchLabel.stringValue.isEmpty

        disclosureButton.isHidden = disclosure == .none
        disclosureButton.show(disclosure)

        applyThrobber(isWorking: row.state == .working)
        applyColours()
        applyAccessibility()
        needsLayout = true
        decorations.needsDisplay = true
    }

    /// The word this row's state gets, or nil for a state that says nothing.
    ///
    /// `InboxState.label` is the shipped vocabulary and is reused verbatim rather
    /// than re-spelled here. What 96 adds is the `ready` case: queue-94 leaves a
    /// resting row unlabelled, and the whole finding of P0.1 was that three of five
    /// terminal outcomes therefore render NO state at all. A finished agent should
    /// say it finished.
    static func stateWord(_ row: AgentInboxRow) -> String? {
        if let label = row.state.label { return label }
        // Ready with nothing else to say is a finished turn nobody has acknowledged.
        return row.isUnconfirmed ? nil : "Done"
    }

    /// Three glyphs, and most rows get none.
    ///
    /// The icon does not name the state — the word beside it does. It answers one
    /// question: is anything here that concerns me? Running, wants-you, and broke
    /// are the three answers worth a mark; done, stopped and cancelled draw
    /// nothing, and the hole is information.
    ///
    /// Approval and input deliberately share the hand. That is NOT the P0.1 defect
    /// of the two sharing a word — the icon says "you are needed" and the word
    /// still says which kind.
    static func attentionSymbol(_ row: AgentInboxRow) -> String? {
        switch row.state {
        case .working: return nil   // the throbber, not a symbol
        case .approval, .input: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .ready: return nil
        }
    }

    private func applyThrobber(isWorking: Bool) {
        guard isWorking else {
            throbber?.removeFromSuperview()
            throbber = nil
            return
        }
        guard throbber == nil else { return }
        let indicator = DualPlaneGyroTiltedThinkingIndicatorView()
        card.addSubview(indicator)
        throbber = indicator
    }

    private func applyColours() {
        guard let shown else { return }
        let row = shown.row
        placementLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        branchLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        modelLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        stateLabel.textColor = Self.accentColour(row, in: self)
        decorations.accent = Self.accentColour(row, in: self)
        decorations.muted = TextToken.textSecondary.color.nsColor(in: self)

        // Recession is the row's words, never its accent: `accentOpacity` paints the
        // state at full strength however far the row recedes, which is queue-94's
        // rule and not one to re-litigate here.
        let alpha = CGFloat(shown.emphasis.textOpacity)
        for label in [placementLabel, titleLabel, branchLabel, modelLabel] {
            label.alphaValue = alpha
        }
        stateLabel.alphaValue = CGFloat(shown.emphasis.accentOpacity)
        decorations.alphaValue = CGFloat(shown.emphasis.accentOpacity)
    }

    /// The row's accent, from the shipped token vocabulary.
    ///
    /// `InboxState.accent` returns nil for `ready` — colour is reserved for
    /// meaning. 96 keeps that: a done row's word is secondary text, not green,
    /// because a list where every finished row is coloured has spent its colour
    /// budget on the rows that need nothing.
    static func accentColour(_ row: AgentInboxRow, in view: NSView) -> NSColor {
        if row.isUnconfirmed { return TextToken.textSecondary.color.nsColor(in: view) }
        guard let accent = row.state.accent else {
            return TextToken.textSecondary.color.nsColor(in: view)
        }
        return accent.color.nsColor(in: view)
    }

    private func applyAccessibility() {
        guard let shown else { return }
        // Everything the row paints, plus the model it deliberately does not print.
        let parts = [
            titleLabel.stringValue,
            stateLabel.isHidden ? nil : stateLabel.stringValue,
            placementLabel.stringValue.isEmpty ? nil : placementLabel.stringValue,
            branchLabel.stringValue.isEmpty ? nil : "branch \(branchLabel.stringValue)",
            shown.row.model.map { "model \($0)" },
        ].compactMap { $0 }.filter { !$0.isEmpty }
        setAccessibilityLabel(parts.joined(separator: ", "))
    }

    // MARK: Layout

    /// Convert a band rectangle into the card's own coordinate space.
    ///
    /// The bands are computed TOP-DOWN, because that is how the anatomy is
    /// specified and how `SidebarDensityProposal` adds it up. `AgentInboxCardView`
    /// is NOT flipped, so handing it those rectangles directly puts band 1 at the
    /// bottom — which is exactly what the first render of this cell did: the model
    /// name appeared above the title and the placement below it. Caught by looking
    /// at the image, and the reason the live render is in the screenshot artifact.
    private func inCard(_ rect: NSRect) -> NSRect {
        guard !card.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: card.bounds.height - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    /// Width a label needs, measured the way the rest of this list measures.
    ///
    /// `+ Metrics.cellTextInset`, and that addend is the whole point. The string
    /// width alone is not the label's width: an `NSTextField` spends some of its
    /// frame on its own inset, so a box sized to the glyphs elides them. Measured
    /// here — `Done` came to 30.0 pt and rendered `Do…`.
    ///
    /// This is the same correction, for the same reason, that
    /// `AgentInboxCellView.minimumTextWidth` already carries: "a floor that
    /// ellipsises its own content is not a floor." Reusing the constant rather than
    /// picking a new fudge means one number moves both.
    private static func width(of label: NSTextField) -> CGFloat {
        guard let font = label.font, !label.stringValue.isEmpty else { return 0 }
        return ceil((label.stringValue as NSString)
            .size(withAttributes: [.font: font]).width) + CGFloat(Metrics.cellTextInset)
    }

    override func layout() {
        super.layout()
        let gutter: CGFloat = 4
        let gap = proposal.gapBetweenRows
        card.frame = NSRect(
            x: gutter + CGFloat(indent), y: gap / 2,
            width: max(0, bounds.width - gutter * 2 - CGFloat(indent)),
            height: max(0, bounds.height - gap))
        decorations.frame = card.bounds

        let insetH: CGFloat = 10
        var textLeft = insetH + anatomy.leadingGutter
        let textRight = card.bounds.width - insetH

        if !disclosureButton.isHidden {
            let side: CGFloat = 14
            disclosureButton.frame = inCard(NSRect(
                x: textLeft, y: (card.bounds.height - side) / 2, width: side, height: side))
            textLeft += side + 3
        }

        var bandY = proposal.insetV
        let iconSide = decorations.isWorking
            ? anatomy.workingIconSide : anatomy.statusIconSide
        let hasIcon = decorations.statusSymbol != nil || decorations.isWorking
        let leadsWithIcon = anatomy.iconPlacement == .leading

        // Band 1 — placement left, state and time right.
        let stateWidth = stateLabel.isHidden
            ? 0 : min(card.bounds.width * 0.55, Self.width(of: stateLabel))
        var placementLeft = textLeft
        var trailingIconWidth: CGFloat = 0
        if leadsWithIcon {
            decorations.statusSlot = hasIcon
                ? NSRect(x: textLeft, y: bandY + (proposal.bandTop - iconSide) / 2,
                         width: iconSide, height: iconSide)
                : nil
            // The slot is NOT reserved when nothing is drawn in it. The column is
            // made of the icons, which are pinned to one x and aligned to each
            // other; reserving the lane only indents band 1 away from the title and
            // branch below it on every row that has no glyph.
            if hasIcon { placementLeft = textLeft + iconSide + 4 }
        } else if hasIcon {
            trailingIconWidth = iconSide + 4
            decorations.statusSlot = NSRect(
                x: textRight - stateWidth - trailingIconWidth,
                y: bandY + (proposal.bandTop - iconSide) / 2,
                width: iconSide, height: iconSide)
        } else {
            decorations.statusSlot = nil
        }
        if let slot = decorations.statusSlot, decorations.isWorking {
            throbber?.frame = inCard(slot)
        }
        placementLabel.frame = inCard(NSRect(
            x: placementLeft, y: bandY,
            width: max(0, textRight - stateWidth - trailingIconWidth - 6 - placementLeft),
            height: proposal.bandTop))
        stateLabel.frame = inCard(NSRect(
            x: textRight - stateWidth, y: bandY,
            width: stateWidth, height: proposal.bandTop))
        bandY += proposal.bandTop + proposal.gapTop

        // Band 2 — the subject. Never sacrificed, at any width.
        titleLabel.frame = inCard(NSRect(
            x: textLeft, y: bandY, width: max(0, textRight - textLeft),
            height: proposal.bandTitle))
        bandY += proposal.bandTitle + proposal.gapBottom

        // Band 3 — branch left, provider mark right.
        let markSide: CGFloat = 14
        let modelWidth = modelLabel.isHidden
            ? 0 : min(card.bounds.width * 0.45, Self.width(of: modelLabel))
        let hasMark = decorations.mark != nil
        let trailing = (hasMark ? markSide : 0)
            + (modelLabel.isHidden ? 0 : modelWidth + (hasMark ? 6 : 0))
        let branchGlyph: CGFloat = decorations.drawsBranchGlyph ? 11 : 0
        decorations.branchSlot = decorations.drawsBranchGlyph
            ? NSRect(x: textLeft, y: bandY + (proposal.bandDetail - branchGlyph) / 2,
                     width: branchGlyph, height: branchGlyph)
            : nil
        let branchLeft = textLeft + branchGlyph + (branchGlyph > 0 ? 4 : 0)
        branchLabel.frame = inCard(NSRect(
            x: branchLeft, y: bandY,
            width: max(0, textRight - trailing - 6 - branchLeft),
            height: proposal.bandDetail))
        decorations.markSlot = hasMark
            ? NSRect(x: textRight - trailing,
                     y: bandY + (proposal.bandDetail - markSide) / 2,
                     width: markSide, height: markSide)
            : nil
        modelLabel.frame = inCard(NSRect(
            x: textRight - modelWidth, y: bandY,
            width: modelWidth, height: proposal.bandDetail))

        decorations.border = anatomy.border
        decorations.borderWidth = anatomy.borderWidth
        decorations.paintsBorder = Self.isAttention(shown?.row)
        decorations.needsDisplay = true

        jumpHint.frame = NSRect(
            x: bounds.width - jumpHint.intrinsicContentSize.width - 8,
            y: (bounds.height - jumpHint.intrinsicContentSize.height) / 2,
            width: jumpHint.intrinsicContentSize.width,
            height: jumpHint.intrinsicContentSize.height)
    }

    /// The states that are asking for a person, as opposed to reporting one. The
    /// card border and the attention glyph use ONE predicate, so a row can never
    /// have an edge treatment saying "look here" and no glyph, or the reverse.
    static func isAttention(_ row: AgentInboxRow?) -> Bool {
        guard let row else { return false }
        switch row.state {
        case .working, .approval, .input, .failed: return true
        case .ready: return false
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // `NSTextField.textColor` is a RESOLVED colour, so the cell repaints its own
        // text rather than the list reloading the table to fix it.
        applyColours()
        decorations.needsDisplay = true
    }

    @objc private func disclosureClicked() { onToggleDisclosure?() }

    // MARK: AgentInboxRowCell

    func applyInteraction(_ interaction: RowInteraction) {
        card.isHovered = interaction.isHovered
        card.isRouteActive = interaction.isRouteActive
        card.hasKeyboardFocus = interaction.hasKeyboardFocus
    }

    func setIncreasedContrast(_ enabled: Bool) { card.usesIncreasedContrast = enabled }

    var accessibilityStatusOwner: NSView { stateLabel }

    func showJumpHint(_ chord: String?) { jumpHint.show(chord) }

    var qaAgentID: UUID? { shown?.row.id }
    var qaVariant: RowVariant? { shown?.row.variant }

    var qaGeometry: AgentInboxRowGeometryForQA {
        let labels = [
            inboxLabelGeometryForQA("project", label: placementLabel, in: self),
            inboxLabelGeometryForQA("title", label: titleLabel, in: self),
            inboxLabelGeometryForQA("state", label: stateLabel, in: self),
            inboxLabelGeometryForQA("branch", label: branchLabel, in: self),
            inboxLabelGeometryForQA("model", label: modelLabel, in: self),
        ]
        return AgentInboxRowGeometryForQA(
            agentID: shown?.row.id,
            state: shown?.row.state,
            variant: shown?.row.variant,
            elementFrames: [
                "cell": bounds,
                "card": card.convert(card.bounds, to: self),
                "project": labels[0].frame,
                "title": labels[1].frame,
                "state": labels[2].frame,
                "branch": labels[3].frame,
                "model": labels[4].frame,
                // Painted, so their frames come off the decoration layer rather
                // than off a view that does not exist.
                "statusGlyph": decorations.statusSlot.map { decorations.convert($0, to: self) }
                    ?? .zero,
                "providerMark": decorations.markSlot.map { decorations.convert($0, to: self) }
                    ?? .zero,
            ],
            labels: labels,
            paintedBorderWidth: card.layer.map { Double($0.borderWidth) },
            resolvedFill: card.layer?.backgroundColor,
            increasedContrast: card.qaUsesIncreasedContrast,
            surfaceRole: card.surfaceRole,
            paintedLines: card.qaPaintedLines,
            isFocusRingVisible: card.qaIsFocusRingVisible,
            accessibilityLabel: accessibilityLabel(),
            // 96 has no measured-fit tiers yet: every band is drawn at every width,
            // which is why the long-title rows in the review images truncate rather
            // than dropping their placement. That ladder is Phase 4, and reporting
            // a tier this cell does not implement would be a claim, not a fact.
            fitTier: nil,
            slimFitTier: nil
        )
    }

    var qaTitle: String { titleLabel.stringValue }
    var qaStateLabel: String { stateLabel.isHidden ? "" : stateLabel.stringValue }
    /// 96 removes the isolation/rollup band entirely — the third band carries the
    /// branch and the provider. Empty here is the design, not a missing accessor.
    var qaMeta: String { "" }
    var qaBranch: String { branchLabel.stringValue }
    /// The elapsed time is part of the state string on this row (`Done · 4m`),
    /// which is what the review images show, so there is no separate label to read.
    var qaElapsed: String { AgentInboxCellView.elapsedText(shown?.row.elapsed) ?? "" }
    /// The status is a PAINTED glyph here, not a text label, so it is reported by
    /// its symbol name — the honest answer for a row that draws rather than writes.
    var qaGlyph: String { decorations.isWorking ? "throbber" : (decorations.statusSymbol ?? "") }
    var qaProviderGlyph: String {
        if decorations.mark != nil { return "mark" }
        return modelLabel.isHidden ? "" : modelLabel.stringValue
    }
    var qaProject: String { placementLabel.stringValue }
    var qaTextAlpha: Double { Double(titleLabel.alphaValue) }
    var qaAccentAlpha: Double { Double(stateLabel.alphaValue) }
    var qaGlyphAlpha: Double { Double(decorations.alphaValue) }
    var qaIndent: Double { indent }
    var qaDisclosureGlyph: String { disclosureButton.qaGlyph }
    var qaJumpHint: String { jumpHint.qaChord }
    var qaJumpHintHitTestPassesThrough: Bool {
        jumpHint.hitTest(NSPoint(x: jumpHint.bounds.midX, y: jumpHint.bounds.midY)) == nil
    }
    var qaStatusFrame: NSRect { stateLabel.convert(stateLabel.bounds, to: self) }
    var titleFrame: NSRect { titleLabel.convert(titleLabel.bounds, to: self) }

    func acceptsRenameDoubleClick(at point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        guard !disclosureButton.isHidden, disclosureButton.isDescendant(of: self) else {
            return true
        }
        return !disclosureButton.convert(disclosureButton.bounds, to: self).contains(point)
    }

    var renameNestedControlFrameForQA: NSRect? {
        guard !disclosureButton.isHidden else { return nil }
        return disclosureButton.convert(disclosureButton.bounds, to: self)
    }

    @discardableResult
    func clickDisclosureForQA() -> Bool {
        guard !disclosureButton.isHidden else { return false }
        disclosureButton.performClick(nil)
        return true
    }
}

// MARK: - Painted decorations

/// The row's three small images and its card border, in one drawing pass.
///
/// One view, not four: this layer draws the status glyph, the branch glyph, the
/// provider mark and the card edge. Rows are recycled by `NSTableView`, so every
/// subview is one more thing to lay out and reset on reuse, and a view per content
/// item is precisely the pattern `docs/internals/performance.md` blames for the
/// Markdown tile freezing the app for three releases.
@MainActor
private final class Decorations: NSView {
    var statusSlot: NSRect?
    var statusSymbol: String?
    var isWorking = false
    var branchSlot: NSRect?
    var drawsBranchGlyph = false
    var markSlot: NSRect?
    var mark: NSImage?
    var accent: NSColor = .labelColor
    var muted: NSColor = .secondaryLabelColor
    var border: SidebarRowAnatomy.Border = .none
    var borderWidth: CGFloat = 0
    var paintsBorder = false

    override var isFlipped: Bool { true }
    /// Decoration only — every click belongs to the row beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if paintsBorder { drawBorder() }
        // The throbber is a real subview of the card, so `isWorking` draws nothing
        // here — the slot is reserved for it and left empty.
        if let slot = statusSlot, let symbol = statusSymbol, !isWorking {
            InkAlignedSymbol.draw(
                symbol, in: slot, colour: accent,
                alignment: .leadingEdge, flipped: isFlipped)
        }
        if let slot = branchSlot, drawsBranchGlyph {
            InkAlignedSymbol.draw(
                "arrow.triangle.branch", in: slot, colour: muted,
                alignment: .centred, flipped: isFlipped)
        }
        if let slot = markSlot, let mark {
            // Flat, in the theme's own colour. §4.5 forbids tinting a vendor mark
            // without per-vendor permission, so this is a REVIEW treatment and the
            // trademark question is open — `brand-marks/PROVENANCE.md`.
            InkAlignedSymbol.drawTinted(
                mark, in: slot, colour: muted.withAlphaComponent(0.85), flipped: isFlipped)
        }
    }

    /// The card-edge treatments. The dashed variant quotes
    /// `FocusBorderOverlayView.lineWidth` and `.dashPattern` rather than inventing
    /// a dash — which is also the argument against choosing it: on the canvas that
    /// exact dash already means "focused tile", and both surfaces are on screen at
    /// once.
    private func drawBorder() {
        let radius: CGFloat = 6
        switch border {
        case .none:
            return
        case .rail, .railThin:
            let rail = NSRect(x: 3, y: 6, width: borderWidth,
                              height: max(0, bounds.height - 12))
            accent.setFill()
            NSBezierPath(roundedRect: rail, xRadius: borderWidth / 2,
                         yRadius: borderWidth / 2).fill()
        case .outline, .dashed:
            let rect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = borderWidth
            if border == .dashed {
                var pattern = FocusBorderOverlayView.dashPattern
                    .map { CGFloat($0.doubleValue) }
                path.setLineDash(&pattern, count: pattern.count, phase: 0)
            }
            accent.setStroke()
            path.stroke()
        case .bracket:
            let rect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = borderWidth
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(
                x: -borderWidth, y: -borderWidth, width: radius + 8,
                height: bounds.height + borderWidth * 2)).setClip()
            accent.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
