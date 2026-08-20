import Foundation
import AppKit
import ContinuumRevivedAgentUI

final class InboxSettleNudgeButton: NSButton {}

// Program 96 — the redesigned agent row, as a REAL cell.
//
// Everything before this was a painting: `SidebarDensityProposalView` draws the
// anatomy into a bitmap so it can be reviewed, and you cannot click it, hover it,
// scroll it or select in it. This is the same anatomy as an `AgentInboxRowCell`,
// so the SHIPPED `AgentInboxView` renders it — with its real scrolling, hover,
// multi-selection, context menus, disclosure triangles, jump pills, rename and
// accessibility, none of which is reimplemented here.
//
// It is the production card. The optional injection seam remains only so the
// Component Lab can render the retired queue-94 cell as a comparison.
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
    static func rect(
        slot: NSRect, ink: NSRect, alignment: Alignment = .centred,
        fraction: CGFloat = inkTargetFraction
    ) -> NSRect {
        let target = slot.width * fraction
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
    ///
    /// `fraction` overrides how much of the slot the ink fills. Every glyph in the
    /// status column takes the default: they are all square, so one fraction gives
    /// them one optical weight. The parameter survives because the density mocks
    /// draw at other sizes.
    static func draw(
        _ name: String, in slot: NSRect, colour: NSColor, alignment: Alignment,
        flipped: Bool, fraction: CGFloat = inkTargetFraction
    ) {
        guard let image = image(name), let ink = ink(name) else { return }
        drawTinted(image, in: rect(slot: slot, ink: ink, alignment: alignment,
                                   fraction: fraction),
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

/// Vendor marks bundled into the app at build time, with a repo-relative fallback
/// for a bare SwiftPM executable. Nothing here performs a network request.
@MainActor
enum BrandMark96 {
    private static var cache: [String: NSImage?] = [:]

    /// Provider silhouettes use the strongest possible monochrome foreground.
    /// `NSColor.labelColor` looks like this treatment but resolves at ~85% alpha;
    /// at 14pt that softness costs real legibility. Resolve explicitly to opaque
    /// black/white from the same appearance mapping as every tokenized view.
    static func foreground(in view: NSView) -> NSColor {
        BrandToken.providerForeground.nsColor(for: view.effectiveTokenTheme)
    }

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
        // Match the provider segment when there is one, and the bare name when
        // there is not: production ids are `provider/model`, but a fixture or a
        // legacy record can carry `gpt-5.6-sol` alone, and a row that shows a mark
        // beside rows that show text is a right-hand column with no rhythm at all.
        let qualified = model.split(separator: "/").first.map(String.init)?.lowercased()
        let bare = model.lowercased()
        let key: String
        switch qualified ?? bare {
        case let p where p.hasPrefix("openai"): key = "openai-light"   // incl. openai-codex
        case let p where p.hasPrefix("anthropic"), let p where p.hasPrefix("claude"):
            key = "anthropic"
        case let p where p.hasPrefix("xai"), let p where p.hasPrefix("grok"):
            key = "xai-light"
        case let p where p.hasPrefix("google"), let p where p.hasPrefix("gemini"):
            key = "gemini"
        case let p where p.hasPrefix("gpt") || p.hasPrefix("o1") || p.hasPrefix("o3"):
            key = "openai-light"
        case let p where p.hasPrefix("opus") || p.hasPrefix("sonnet")
                        || p.hasPrefix("haiku"):
            key = "anthropic"
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
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("BrandMarks", isDirectory: true)
            .appendingPathComponent("\(key).svg")
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // App
            .deletingLastPathComponent()   // ContinuumRevived
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(
                "docs/38-tickets/96-agent-sidebar-product-redesign/brand-marks/\(key).svg")
        let url = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? source
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
    static let statusSymbolsInUse = [
        "checkmark.circle.fill", "hand.raised.fill",
        "exclamationmark.triangle.fill", "stop.circle.fill", "xmark.circle.fill",
    ]
    /// Pitch and anatomy for THIS cell, handed in by whoever built it, so the Lab
    /// can retune live without a static anyone else can see.
    let proposal: SidebarDensityProposal
    let anatomy: SidebarRowAnatomy

    private let card = AgentInboxCardView()
    private let jumpHint = InboxJumpHintView()
    private let disclosureButton = InboxDisclosureButton()
    var onToggleDisclosure: (() -> Void)?
    private let settleNudge = InboxSettleNudgeButton(frame: .zero)
    private var onSettleNudge: (() -> Void)?

    private let placementLabel = NSTextField(labelWithString: "")
    private let projectIcon = NSImageView(frame: .zero)
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
                        isSelected: Bool, now: Date)?
    /// Whether motion is allowed. Injected rather than read from the system here so
    /// the QA seam the list already owns (`AgentInboxView.prefersReducedMotion`) can
    /// drive it, and so a check can render both branches.
    private let prefersReducedMotion: () -> Bool
    /// The leading status glyph. A VIEW, not a painted decoration, for one reason:
    /// it is the only thing on the row that can animate.
    private let statusGlyph = StatusGlyphView()
    private var layoutColumnWidth: Double?
    private var indent: Double = 0

    /// The row height this anatomy needs: the card, plus the gap that separates it
    /// from the next one. Every band is always drawn, which is the entire point of
    /// the redesign, so unlike the queue-94 row this does not vary with content.
    static func rowHeight(for proposal: SidebarDensityProposal) -> Double {
        Double(proposal.pitch)
    }

    init(
        proposal: SidebarDensityProposal, anatomy: SidebarRowAnatomy,
        prefersReducedMotion: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    ) {
        self.proposal = proposal
        self.anatomy = anatomy
        self.prefersReducedMotion = prefersReducedMotion
        super.init(frame: NSRect(x: 0, y: 0, width: 280,
                                 height: Self.rowHeight(for: proposal)))
        wantsLayer = true

        addSubview(card)
        card.addSubview(decorations)
        card.addSubview(statusGlyph)

        placementLabel.font = .token(.caption)
        projectIcon.imageScaling = .scaleProportionallyDown
        projectIcon.setAccessibilityElement(false)
        card.addSubview(projectIcon)
        // Status is telemetry, not a heading. Keep the label rung's 11pt size so
        // it fits the fixed 14pt band, but use a regular monospaced face: the
        // changing word/time pair stays quiet and its digits do not breathe.
        stateLabel.font = .monospacedSystemFont(
            ofSize: Typography.style(for: .label).size, weight: .regular)
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
        settleNudge.title = "All set?  ×"
        settleNudge.image = NSImage(
            systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        settleNudge.imagePosition = .imageLeading
        settleNudge.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        settleNudge.isBordered = false
        settleNudge.wantsLayer = true
        settleNudge.layer?.cornerRadius = 11
        settleNudge.target = self
        settleNudge.action = #selector(settleNudgeClicked)
        settleNudge.isHidden = true
        settleNudge.setAccessibilityLabel("Settle agent")
        settleNudge.setAccessibilityIdentifier("ContinuumAgentInboxSettleNudge")
        card.addSubview(settleNudge)
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
        shown = (row, emphasis, indent, disclosure, rollup, isSelected, now)
        self.indent = indent
        card.isSelected = isSelected

        placementLabel.stringValue = row.projectName ?? ""
        projectIcon.image = row.projectName?.isEmpty == false
            ? NSImage(systemSymbolName: "folder", accessibilityDescription: nil) : nil
        projectIcon.image?.isTemplate = true
        titleLabel.stringValue = row.displayTitle
        let rollupSummary: String?
        if disclosure == .collapsed {
            rollupSummary = rollup?.summary
        } else {
            rollupSummary = rollup?.cappedAttentionSummary
        }
        // A folded parent has to speak for the rows it hides. The compact card has
        // no fourth metadata band, so that transient structural fact takes the
        // branch lane while folded; the exact branch remains in the hover card.
        branchLabel.stringValue = rollupSummary ?? row.branch ?? ""

        // The state WORD and, only while executing, its live duration. The elapsed
        // half comes from the shipped formatter, so every surface uses one clock
        // vocabulary.
        updateStateLabel(for: row, now: now)

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

        statusGlyph.symbol = Self.attentionSymbol(row, now: now)
        statusGlyph.alignment =
            anatomy.iconPlacement == .leading ? .leadingEdge : .centred
        // Nothing on a resting row moves. An earlier design pulsed the mark on a
        // finished row nobody had read; that motion is gone, because the thing it
        // was worried about is not an unread row (which is already coloured and
        // marked) but a row you read and then left lying there forever. That one is
        // the settle nudge's job, and it is a different row entirely.
        statusGlyph.setPulsing(false)
        decorations.isWorking = row.state == .working
        decorations.drawsBranchGlyph = rollupSummary == nil && !branchLabel.stringValue.isEmpty

        disclosureButton.isHidden = disclosure == .none
        disclosureButton.show(disclosure)

        applyThrobber(isWorking: row.state == .working)
        applyColours()
        applyAccessibility()
        needsLayout = true
        decorations.needsDisplay = true
    }

    /// How long a finished row you have ALREADY READ sits before it asks to be put
    /// away. The settle nudge's threshold, not a status change.
    ///
    /// The row this protects against is not the unread one — that one is already
    /// coloured, marked, and sorted where you will see it. It is the one you read
    /// two hours ago, said "yep", and never closed. Forty of those and the list is
    /// a graveyard you have to read past to find live work.
    static let settleNudgeDelay: TimeInterval = 10 * 60

    /// Work that finished and nobody has looked at it.
    ///
    /// Both halves come off the existing model — nothing new is invented and nothing
    /// new is stored. `InboxState.ready` is a row with no live turn, and
    /// `InboxAttention.unread` is queue-94's own "you have not seen this", whose
    /// doc comment already says the thing this design needs: *"Unread is a MARK,
    /// not a word."*
    ///
    /// The whole lifecycle of a finished row is three steps and no vocabulary to
    /// learn: it says `Done` in mint with a check, you look at it and it goes
    /// silent, and if you leave it silent for long enough it asks to be settled.
    /// Earlier drafts spent two words (`Landed`, `Waiting`) and a pulsing mark on
    /// the first step alone, which was effort spent on the row that needed it
    /// least.
    static func isUnseen(_ row: AgentInboxRow) -> Bool {
        guard row.state == .ready, !row.isUnconfirmed else { return false }
        if let terminal = row.terminalEvent {
            return terminal.outcome == .succeeded && row.terminalIsUnread
        }
        return row.attention == .unread
    }

    /// A finished row you have read and left sitting. What the settle nudge asks
    /// about — see `settleNudgeDelay`.
    static func isSettleCandidate(_ row: AgentInboxRow, now: Date) -> Bool {
        guard row.state == .ready, !row.terminalIsUnread, !isUnseen(row), !row.isUnconfirmed,
              case .active = row.lifecycle, let since = row.lastActiveAt
        else { return false }
        if let outcome = row.terminalEvent?.outcome, outcome != .succeeded { return false }
        return now.timeIntervalSince(since) >= settleNudgeDelay
    }

    /// The word this row's state gets, or nil for a state that says nothing.
    ///
    /// `InboxState.label` is the shipped vocabulary, reused verbatim. What 96 adds is
    /// the resting case: queue-94 leaves `.ready` unlabelled, which is why P0.1 found
    /// three of five terminal outcomes rendering NO state at all. A finished agent
    /// should say it finished, and one nobody has looked at should say more than that.
    static func stateWord(_ row: AgentInboxRow, now: Date) -> String? {
        if let label = row.state.label { return label }
        guard !row.isUnconfirmed else { return nil }
        // `.ready` says `Done` until you look at it, and then says nothing at all.
        //
        // Looking IS the acknowledgement, and the reward for it is a row that stops
        // talking — a settled row keeps its age, because "when did this land" is a
        // fair question, but it has no status left to report. What eventually gets
        // it off the list is the nudge to settle, not another word here.
        guard let terminal = row.terminalEvent else {
            return isUnseen(row) ? "Done" : nil
        }
        switch terminal.outcome {
        case .succeeded:
            return row.terminalIsUnread ? "Done" : nil
        case .failed, .runtimeError:
            return "Failed"
        case .interrupted:
            return "Stopped"
        case .cancelled:
            return "Cancelled"
        }
    }

    /// The number beside the word is current execution duration, never age since
    /// completion. Completion time belongs in hover/history detail; showing it on
    /// a ready row produces an unexplained bare `5m` after `Done` is acknowledged.
    static func stateAge(_ row: AgentInboxRow, now: Date) -> TimeInterval? {
        guard row.state == .working else { return nil }
        if let since = row.elapsedStartedAt {
            return max(0, now.timeIntervalSince(since))
        }
        return row.elapsed
    }

    private func updateStateLabel(for row: AgentInboxRow, now: Date) {
        let word = Self.stateWord(row, now: now)
        let elapsed = AgentInboxCellView.elapsedText(Self.stateAge(row, now: now))
        stateLabel.stringValue = [word, elapsed].compactMap { $0 }.joined(separator: " · ")
        stateLabel.isHidden = stateLabel.stringValue.isEmpty
    }

    /// Called by the inbox's one shared clock. This changes and locally reflows
    /// only the status band; it does not rebuild the row or invalidate transcript/
    /// canvas layout, and a non-working row is a no-op by construction.
    func updateElapsedClock(now: Date) {
        guard let row = shown?.row, row.state == .working else { return }
        updateStateLabel(for: row, now: now)
        needsLayout = true
        applyAccessibility()
    }

    /// Three glyphs, and most rows get none.
    ///
    /// The icon does not name the state — the word beside it does. It answers one
    /// question: is anything here that concerns me? Running, wants-you, broke, and
    /// (rule 2) finished-but-unseen. Everything else draws nothing, and the hole is
    /// information.
    ///
    /// Approval and input deliberately share the hand. That is NOT the P0.1 defect
    /// of the two sharing a word — the icon says "you are needed" and the word still
    /// says which kind.
    ///
    /// A finished row takes `checkmark.circle.fill` — it states the outcome, and it
    /// is square, which matters more than it sounds: the column scales each symbol
    /// by its LARGEST dimension, so a wide symbol lands visually smaller than its
    /// neighbours. Every glyph in this column is square for that reason.
    static func attentionSymbol(_ row: AgentInboxRow, now: Date) -> String? {
        if isUnseen(row) { return "checkmark.circle.fill" }
        switch row.state {
        case .working: return nil   // the throbber, not a symbol
        case .approval, .input: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .ready:
            guard row.terminalIsUnread, let outcome = row.terminalEvent?.outcome else { return nil }
            switch outcome {
            case .succeeded: return "checkmark.circle.fill"
            case .failed, .runtimeError: return "exclamationmark.triangle.fill"
            case .interrupted: return "stop.circle.fill"
            case .cancelled: return "xmark.circle.fill"
            }
        }
    }

    /// The app's own throbber, added only while a row is working.
    ///
    /// It has to be told to run. The first version of this cell added the view and
    /// never called `startAnimating()`, so the sidebar showed a frozen gyro — three
    /// dots that looked like a rendering bug rather than a running agent. Under
    /// Reduce Motion it is posed at a fixed phase instead, which is what
    /// `setSnapshotPhase` exists for.
    private func applyThrobber(isWorking: Bool) {
        guard isWorking else {
            throbber?.stopAnimating()
            throbber?.removeFromSuperview()
            throbber = nil
            return
        }
        if throbber == nil {
            let indicator = DualPlaneGyroTiltedThinkingIndicatorView(
                reducedMotion: prefersReducedMotion())
            card.addSubview(indicator)
            throbber = indicator
        }
        if prefersReducedMotion() {
            throbber?.setSnapshotPhase(0.32)
        } else {
            throbber?.startAnimating()
        }
    }

    private func applyColours() {
        guard let shown else { return }
        let row = shown.row
        placementLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        projectIcon.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        branchLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        modelLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        let accent = Self.accentColour(row, now: shown.now, in: self)
        stateLabel.textColor = accent
        decorations.accent = accent
        statusGlyph.colour = accent
        decorations.muted = TextToken.textSecondary.color.nsColor(in: self)
        // Provider marks are silhouettes, not metadata text. Full-strength
        // Opaque black in Aqua and white in Dark Aqua gives the tiny 14pt artwork
        // maximum contrast without recolouring the vendor shape by status or row
        // recession.
        decorations.markColour = BrandMark96.foreground(in: self)
        let nudgeForeground = TextToken.textPrimary.color.nsColor(in: self)
        settleNudge.contentTintColor = nudgeForeground
        settleNudge.attributedTitle = NSAttributedString(
            string: settleNudge.title,
            attributes: [.font: settleNudge.font as Any, .foregroundColor: nudgeForeground])
        settleNudge.layer?.backgroundColor = SidebarSurfaceRole.hover.color.cgColor(in: self)

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

    /// One colour per meaning — with the two kinds of *asking* sharing one.
    ///
    /// Ruled 2026-08-14, after a first attempt collapsed the palette too far. The
    /// defect was never "too many colours", it was **two colours for one meaning**:
    /// the capability render showed `Needs attention` in amber directly above
    /// `Needs attention` in violet, same words and same glyph. Approval and input
    /// are one thing to a reader — a decision is wanted — so they take one colour.
    /// Everything else stays distinguishable, because a list where failure and
    /// success look alike is worse than one with five hues in it.
    ///
    /// | state | colour | why |
    /// |---|---|---|
    /// | working | blue, plus the moving glyph | in flight, wants nothing |
    /// | approval, input | amber | a decision is wanted — ONE colour for both |
    /// | failed | red | it broke |
    /// | unseen | mint | finished, and nobody has looked |
    /// | done, and you saw it | **no colour** | it went well, it is closed, it is over |
    ///
    /// Ruled 2026-08-14, round 8. Two changes, and the second is what makes the
    /// first legal.
    ///
    /// The rose that carried "unseen" was 21° of hue from the failure red, so a
    /// finished row and a broken one read as the same kind of event at a glance.
    /// Mint replaces it: `Unseen` is a *finished* state, nobody is blocked, and the
    /// green family says exactly that — the family resemblance to a row you already
    /// read is the point, since the only difference between them is whether you
    /// looked.
    ///
    /// Which is why **`.ready` returns nil**. Mint sits 25° from the old
    /// `accentDone` green — the same near-miss, one hue over. Retiring green from
    /// the row costs nothing (a settled row is the one row asking for nothing) and
    /// buys mint a 48° gap to its nearest neighbour, the widest in the palette.
    /// Colour on a row now means one thing and one thing only: this wants you.
    ///
    /// A done row is not left to rot, either — see the nudge pill, which is how it
    /// eventually asks to be put away.
    static func accentToken(_ row: AgentInboxRow, now: Date) -> AccentToken? {
        if isUnseen(row) { return .accentReview }
        switch row.state {
        case .working: return .accentWorking
        // ONE colour for the two kinds of asking. This deliberately drops
        // `accentInput`'s violet on a ROW; the status chip keeps it, because a chip
        // is read one at a time and a list is read as a column.
        case .approval, .input: return .accentApproval
        case .failed: return .accentFailed
        // Seen, finished, closed. `accentColour` routes nil to `textSecondary`.
        case .ready:
            guard row.terminalIsUnread, let outcome = row.terminalEvent?.outcome else { return nil }
            switch outcome {
            case .succeeded: return .accentReview
            case .failed, .runtimeError: return .accentFailed
            case .interrupted, .cancelled: return nil
            }
        }
    }

    static func accentColour(_ row: AgentInboxRow, now: Date, in view: NSView) -> NSColor {
        // An unconfirmed row is one whose state we are not sure of, and colour is a
        // claim. Grey until it is known.
        guard !row.isUnconfirmed, let token = accentToken(row, now: now) else {
            return TextToken.textSecondary.color.nsColor(in: view)
        }
        return token.color.nsColor(in: view)
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
        var statusSlot: NSRect?
        let iconSide = decorations.isWorking
            ? anatomy.workingIconSide : anatomy.statusIconSide
        let hasIcon = statusGlyph.symbol != nil || decorations.isWorking
        let leadsWithIcon = anatomy.iconPlacement == .leading

        // Band 1 — placement left, state and time right.
        let stateWidth = stateLabel.isHidden
            ? 0 : min(card.bounds.width * 0.55, Self.width(of: stateLabel))
        var placementLeft = textLeft
        if projectIcon.image != nil {
            let side: CGFloat = 12
            projectIcon.frame = inCard(NSRect(
                x: placementLeft, y: bandY + (proposal.bandTop - side) / 2,
                width: side, height: side))
            placementLeft += side + 4
        } else {
            projectIcon.frame = .zero
        }
        var trailingIconWidth: CGFloat = 0
        if leadsWithIcon {
            statusSlot = hasIcon
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
            statusSlot = NSRect(
                x: textRight - stateWidth - trailingIconWidth,
                y: bandY + (proposal.bandTop - iconSide) / 2,
                width: iconSide, height: iconSide)
        } else {
            statusSlot = nil
        }
        statusGlyph.isHidden = statusSlot == nil || decorations.isWorking
        if let slot = statusSlot {
            if decorations.isWorking {
                throbber?.frame = inCard(slot)
            } else {
                statusGlyph.frame = inCard(slot)
            }
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
        decorations.paintsBorder = Self.isAttention(shown?.row, now: shown?.now ?? Date())
        decorations.needsDisplay = true

        jumpHint.frame = NSRect(
            x: bounds.width - jumpHint.intrinsicContentSize.width - 8,
            y: (bounds.height - jumpHint.intrinsicContentSize.height) / 2,
            width: jumpHint.intrinsicContentSize.width,
            height: jumpHint.intrinsicContentSize.height)
        let nudgeSize = NSSize(width: 94, height: 22)
        settleNudge.frame = inCard(NSRect(
            x: max(textLeft, textRight - nudgeSize.width),
            y: (card.bounds.height - nudgeSize.height) / 2,
            width: nudgeSize.width, height: nudgeSize.height))
    }

    /// The states that are asking for a person, as opposed to reporting one. The
    /// card border and the attention glyph use ONE predicate, so a row can never
    /// have an edge treatment saying "look here" and no glyph, or the reverse.
    static func isAttention(_ row: AgentInboxRow?, now: Date) -> Bool {
        guard let row else { return false }
        if isUnseen(row) { return true }
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
    @objc private func settleNudgeClicked() { onSettleNudge?() }

    func showSettleNudge(_ shown: Bool, onSettle: (() -> Void)?) {
        onSettleNudge = shown ? onSettle : nil
        guard settleNudge.isHidden == shown else { return }
        settleNudge.isHidden = !shown
        guard shown, !prefersReducedMotion(), let layer = settleNudge.layer else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 14
        slide.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = 0.22
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "settle-nudge-arrive")
    }

    func setProjectIcon(_ image: NSImage?, for rowID: UUID) {
        guard shown?.row.id == rowID, let image else { return }
        projectIcon.image = image
        projectIcon.contentTintColor = nil
        needsLayout = true
    }

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
                "statusGlyph": statusGlyph.isHidden
                    ? (throbber.map { $0.convert($0.bounds, to: self) } ?? .zero)
                    : statusGlyph.convert(statusGlyph.bounds, to: self),
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
    /// The compact card borrows the branch lane for a folded/capped child rollup.
    var qaMeta: String {
        guard let shown else { return "" }
        if shown.disclosure == .collapsed { return shown.rollup?.summary ?? "" }
        return shown.rollup?.cappedAttentionSummary ?? ""
    }
    var qaBranch: String { branchLabel.stringValue }
    /// Elapsed is part of the working state string, so there is no second label.
    var qaElapsed: String {
        guard let shown else { return "" }
        return AgentInboxCellView.elapsedText(Self.stateAge(shown.row, now: shown.now)) ?? ""
    }
    /// The status is a PAINTED glyph here, not a text label, so it is reported by
    /// its symbol name — the honest answer for a row that draws rather than writes.
    var qaGlyph: String { decorations.isWorking ? "throbber" : (statusGlyph.symbol ?? "") }
    /// Whether the escalated review mark is actually animating right now — the one
    /// fact about rule 2 that a still image cannot carry.
    var qaIsPulsingForQA: Bool { statusGlyph.isPulsing }
    var qaProviderGlyph: String {
        if decorations.mark != nil { return "mark" }
        return modelLabel.isHidden ? "" : modelLabel.stringValue
    }
    var qaProject: String { placementLabel.stringValue }
    var qaTextAlpha: Double { Double(titleLabel.alphaValue) }
    var qaAccentAlpha: Double { Double(stateLabel.alphaValue) }
    var qaGlyphAlpha: Double { Double(statusGlyph.alphaValue) }
    var qaIndent: Double { indent }
    var qaDisclosureGlyph: String { disclosureButton.qaGlyph }
    var qaJumpHint: String { jumpHint.qaChord }
    var qaJumpHintHitTestPassesThrough: Bool {
        jumpHint.hitTest(NSPoint(x: jumpHint.bounds.midX, y: jumpHint.bounds.midY)) == nil
    }
    var qaStatusFrame: NSRect { stateLabel.convert(stateLabel.bounds, to: self) }
    var qaStatusFontForQA: NSFont? { stateLabel.font }
    var qaProviderMarkColourForQA: NSColor { decorations.markColour }
    var titleFrame: NSRect { titleLabel.convert(titleLabel.bounds, to: self) }

    func acceptsRenameDoubleClick(at point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        if !settleNudge.isHidden,
           settleNudge.convert(settleNudge.bounds, to: self).contains(point) { return false }
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

// MARK: - The status glyph

/// The leading attention mark, and the only thing on a resting row that can move.
///
/// A view rather than another painted decoration for exactly one reason: rule 2's
/// escalation is a pulse, and you cannot animate a rectangle inside somebody else's
/// `draw(_:)`. Everything else the row decorates with — the branch glyph, the
/// provider mark, the card edge — stays painted.
///
/// THE PULSE IS DELIBERATELY SLOW. 2.0 s per cycle is about 0.5 Hz, far below the
/// 3 Hz where flashing becomes a seizure risk, and it bottoms out at 0.4 rather
/// than 0 so the mark never disappears — a glyph that vanishes reads as a
/// rendering fault, not as insistence. It is also rare by construction: only a
/// finished row nobody has looked at for ten minutes gets one.
@MainActor
final class StatusGlyphView: NSView {
    var symbol: String? { didSet { needsDisplay = true } }
    var colour = TextToken.textPrimary.color.nsColor(for: TokenTheme.light) {
        didSet { needsDisplay = true }
    }
    var inkFraction: CGFloat = InkAlignedSymbol.inkTargetFraction {
        didSet { needsDisplay = true }
    }
    var alignment: InkAlignedSymbol.Alignment = .leadingEdge {
        didSet { needsDisplay = true }
    }
    private(set) var isPulsing = false

    private static let animationKey = "reviewPulse"
    private static let period: CFTimeInterval = 2.0
    private static let floorOpacity: Float = 0.4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    /// Decoration only — the click belongs to the row.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setPulsing(_ pulsing: Bool) {
        guard pulsing != isPulsing else { return }
        isPulsing = pulsing
        guard pulsing else {
            layer?.removeAnimation(forKey: Self.animationKey)
            layer?.opacity = 1
            return
        }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = Self.floorOpacity
        pulse.duration = Self.period / 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(pulse, forKey: Self.animationKey)
    }

    /// A recycled cell must not inherit the previous row's pulse.
    override func prepareForReuse() {
        super.prepareForReuse()
        setPulsing(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbol else { return }
        InkAlignedSymbol.draw(
            symbol, in: bounds, colour: colour, alignment: alignment,
            flipped: isFlipped, fraction: inkFraction)
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
    var isWorking = false
    var branchSlot: NSRect?
    var drawsBranchGlyph = false
    var markSlot: NSRect?
    var mark: NSImage?
    var accent = TextToken.textPrimary.color.nsColor(for: TokenTheme.light)
    var muted = TextToken.textSecondary.color.nsColor(for: TokenTheme.light)
    var markColour = BrandToken.providerForeground.nsColor(for: TokenTheme.light)
    var border: SidebarRowAnatomy.Border = .none
    var borderWidth: CGFloat = 0
    var paintsBorder = false

    override var isFlipped: Bool { true }
    /// Decoration only — every click belongs to the row beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        if paintsBorder { drawBorder() }
        if let slot = branchSlot, drawsBranchGlyph {
            InkAlignedSymbol.draw(
                "arrow.triangle.branch", in: slot, colour: muted,
                alignment: .centred, flipped: isFlipped)
        }
        if let slot = markSlot, let mark {
            // Full-strength black in Aqua, white in Dark Aqua. The old secondary
            // colour at 85% made already-tiny vendor silhouettes needlessly faint.
            // §4.5's trademark question remains open — `brand-marks/PROVENANCE.md`.
            InkAlignedSymbol.drawTinted(
                mark, in: slot, colour: markColour, flipped: isFlipped)
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
