import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Geometry assertions over a `UIProbe`-rendered tree — layout bugs caught with
/// numbers instead of eyes.
///
/// Both layout bugs this program shipped passed every gate that existed:
/// a transcript whose cards sized themselves to the longest line and floated
/// centred at half the tile width (the scroller stranded mid-tile), and a
/// transcript whose cards never laid out at all. Neither is visible to a
/// "more than one colour" check; both are trivially visible to a width ratio
/// and a count.
///
/// Deliberately ratios and invariants, never exact frames: exact pixel frames
/// move with font metrics and would make this gate flaky rather than strict.
@MainActor
enum UIProbeGeometry {
    struct GeometryError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func fail(_ message: String) -> GeometryError { GeometryError(message: message) }

    // MARK: - Assertions

    /// `child` must span at least `minRatio` of `parent`'s width. The direct
    /// witness for the half-width transcript.
    static func fills(child: NSView, parent: NSView, minRatio: Double, label: String) throws {
        guard parent.bounds.width > 0 else {
            throw fail("\(label): parent laid out to zero width")
        }
        let ratio = child.bounds.width / parent.bounds.width
        guard ratio >= minRatio else {
            throw fail(String(
                format: "%@: spans %.3f of parent width (%.1fpt of %.1fpt), needs >= %.3f",
                label, ratio, child.bounds.width, parent.bounds.width, minRatio
            ))
        }
    }

    /// Every visible view in the subtree must have a real size. The witness for
    /// the transcript that had cards in the model and nothing on screen.
    static func expectNoZeroSizeViews(_ root: NSView, label: String) throws {
        try walk(root) { view, path in
            guard view.bounds.width > 0, view.bounds.height > 0 else {
                throw fail(String(
                    format: "%@: %@ laid out to %.1fx%.1f", label, path, view.bounds.width, view.bounds.height
                ))
            }
        }
    }

    /// AppKit reports the exact class of bug that shipped — a stack row with no
    /// width pin — for free, but only over a laid-out tree.
    ///
    /// Takes an explicit view list rather than walking the subtree, because
    /// `hasAmbiguousLayout` is true for *every* flexible `NSStackView` child that
    /// AppKit positions with its low-priority (260) `NSStackView.Align`
    /// constraint: the header's name/phase labels and the approval dock's button
    /// row all report it today, and all lay out correctly. Widening the walk would
    /// force weakening the assertion; scoping it keeps it absolute over the
    /// transcript column — the chain the shipped bug actually lived in.
    static func expectNoAmbiguousLayout(_ views: [(NSView, String)], label: String) throws {
        for (view, name) in views {
            view.layoutSubtreeIfNeeded()
            guard !view.hasAmbiguousLayout else {
                throw fail("\(label): \(name) (\(describe(view))) has ambiguous layout")
            }
        }
    }

    static func expectCount(_ actual: Int, _ expected: Int, label: String) throws {
        guard actual == expected else {
            throw fail("\(label): \(actual), expected \(expected)")
        }
    }

    /// The clip view must sit at its maximum offset — the newest card visible.
    /// `requireOverflow` keeps the assertion from passing vacuously: a document
    /// shorter than its clip view is always "at the bottom".
    static func expectScrolledToBottom(_ scrollView: NSScrollView, requireOverflow: Bool, label: String) throws {
        guard let document = scrollView.documentView else {
            throw fail("\(label): scroll view has no document view")
        }
        let clip = scrollView.contentView
        let maxY = max(0, document.bounds.height - clip.bounds.height)
        if requireOverflow {
            guard maxY > 0 else {
                throw fail(String(
                    format: "%@: document (%.1fpt) does not overflow its clip view (%.1fpt), so the scroll assertion would pass vacuously",
                    label, document.bounds.height, clip.bounds.height
                ))
            }
        }
        guard abs(clip.bounds.origin.y - maxY) <= 1 else {
            throw fail(String(
                format: "%@: clip offset %.1f, expected %.1f (document %.1fpt, clip %.1fpt)",
                label, clip.bounds.origin.y, maxY, document.bounds.height, clip.bounds.height
            ))
        }
    }

    /// No visible view may spill outside its superview — the narrow-width
    /// clipping gate. The single exception is a clip view's own child: a document
    /// view is *supposed* to be taller than its clip view.
    ///
    /// Compares **alignment** rects, not frames: `NSTextField` carries a ~2pt
    /// alignment inset, so a label flush with its stack's leading edge sits at
    /// frame x = -2 by design. Frame containment would fail on every label here.
    static func expectNoClipping(_ root: NSView, label: String) throws {
        func check(_ view: NSView, path: String) throws {
            // Only a clip view's own children — the document view — are exempt from
            // vertical containment; a document view is supposed to be taller than
            // its clip. The exemption deliberately does NOT inherit, so a label
            // spilling out of a transcript card *inside* the scroll view still
            // fails.
            let childInsideScroll = view is NSClipView
            for subview in view.subviews where !subview.isHidden {
                let childPath = "\(path)/\(describe(subview))"
                if !isSpacer(subview) {
                    let bounds = view.bounds
                    let frame = subview.alignmentRect(forFrame: subview.frame)
                    guard frame.minX >= bounds.minX - 0.5, frame.maxX <= bounds.maxX + 0.5 else {
                        throw fail(String(
                            format: "%@: %@ spills horizontally — frame x %.1f…%.1f outside parent 0…%.1f",
                            label, childPath, frame.minX, frame.maxX, bounds.width
                        ))
                    }
                    if !childInsideScroll {
                        guard frame.minY >= bounds.minY - 0.5, frame.maxY <= bounds.maxY + 0.5 else {
                            throw fail(String(
                                format: "%@: %@ spills vertically — frame y %.1f…%.1f outside parent 0…%.1f",
                                label, childPath, frame.minY, frame.maxY, bounds.height
                            ))
                        }
                    }
                }
                try check(subview, path: childPath)
            }
        }
        try check(root, path: describe(root))
    }

    // MARK: - Unsatisfiable constraints

    /// The "no unsatisfiable constraints" half of the narrow-width pass, evaluated
    /// rather than read: every active **required** width/height constraint *owned by
    /// a view in this subtree* must actually hold once the tree is laid out. (A
    /// constraint installed on an ancestor above `root` is out of reach; for the
    /// probed tile there is no such ancestor — the probe host uses frames.) A required constraint
    /// AppKit had to break is a required constraint that does not hold.
    ///
    /// AppKit's own "Unable to simultaneously satisfy constraints" report is not
    /// usable here — measured: with two conflicting required header heights, a
    /// probe process that never calls `NSApp.run()` emits nothing on stderr (the
    /// report goes through unified logging), so a capture-stderr gate would be a
    /// gate that can never fire.
    ///
    /// Scoped to size attributes on purpose: they are independent of view
    /// flipped-ness, and this tree mixes flipped (`FlippedStackView`) and
    /// unflipped containers, so edge attributes could not be compared across it
    /// without guessing. Position breakage surfaces instead through
    /// `expectNoClipping` and the fill ratios.
    static func expectNoBrokenRequiredSizeConstraints(_ root: NSView, label: String) throws {
        let tolerance = 0.51
        try walk(root) { view, path in
            for constraint in view.constraints where constraint.isActive && constraint.priority == .required {
                // Skip AppKit's own generated subclasses, which report `.required`
                // while being breakable by design: `NSContentSizeLayoutConstraint`
                // carries its real strength in the view's hugging (251) and
                // compression-resistance (750) priorities, so an intrinsically
                // 28pt-wide label compressed to 21.5pt reads as a broken required
                // constraint — measured, on unmodified code. Only `NS`-prefixed
                // subclasses are skipped, so an app-defined subclass is still gated.
                let constraintClass = type(of: constraint)
                if constraintClass != NSLayoutConstraint.self,
                   String(describing: constraintClass).hasPrefix("NS") { continue }
                guard let first = constraint.firstItem as? NSView,
                      let lhs = sizeValue(constraint.firstAttribute, of: first) else { continue }
                var rhs = 0.0
                if constraint.secondAttribute != .notAnAttribute {
                    guard let second = constraint.secondItem as? NSView,
                          let value = sizeValue(constraint.secondAttribute, of: second) else { continue }
                    rhs = value
                }
                let target = rhs * Double(constraint.multiplier) + Double(constraint.constant)
                let holds: Bool
                switch constraint.relation {
                case .equal: holds = abs(lhs - target) <= tolerance
                case .greaterThanOrEqual: holds = lhs >= target - tolerance
                case .lessThanOrEqual: holds = lhs <= target + tolerance
                @unknown default: continue
                }
                guard holds else {
                    throw fail(String(
                        format: "%@: %@ holds a broken required constraint — measured %.1f, needs %@ %.1f (%@)",
                        label, path, lhs,
                        constraint.relation == .equal ? "==" : (constraint.relation == .greaterThanOrEqual ? ">=" : "<="),
                        target, "\(constraint)"
                    ))
                }
            }
        }
    }

    /// Alignment-rect size for the two attributes this gate evaluates; `nil` for
    /// anything else, which the caller skips. Alignment rects, not frames, because
    /// that is what Auto Layout constrains.
    private static func sizeValue(_ attribute: NSLayoutConstraint.Attribute, of view: NSView) -> Double? {
        let rect = view.alignmentRect(forFrame: view.frame)
        switch attribute {
        case .width: return rect.width
        case .height: return rect.height
        default: return nil
        }
    }

    // MARK: - Walking

    /// Depth-first over visible, non-spacer views, `self` included.
    private static func walk(_ root: NSView, _ body: (NSView, String) throws -> Void) throws {
        func visit(_ view: NSView, path: String) throws {
            if !isSpacer(view) { try body(view, path) }
            for subview in view.subviews where !subview.isHidden {
                try visit(subview, path: "\(path)/\(describe(subview))")
            }
        }
        guard !root.isHidden else { return }
        try visit(root, path: describe(root))
    }

    /// `NSStackView` rows are padded with a bare `NSView()` to push content apart
    /// (`ManagedAgentTileNSView.configureHeader` does exactly this). Such a view
    /// has no size of its own on the cross axis and nothing pinning it, so it is
    /// neither a zero-size bug nor an ambiguity bug. Recognised narrowly — exactly
    /// `NSView`, no subviews, no intrinsic content size — so scoping it out cannot
    /// silently excuse a real component.
    private static func isSpacer(_ view: NSView) -> Bool {
        type(of: view) == NSView.self
            && view.subviews.isEmpty
            && view.intrinsicContentSize.width == NSView.noIntrinsicMetric
            && view.intrinsicContentSize.height == NSView.noIntrinsicMetric
    }

    private static func describe(_ view: NSView) -> String {
        let name = String(describing: type(of: view))
        if let id = view.identifier?.rawValue { return "\(name)#\(id)" }
        return name
    }

    private static func firstDescendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstDescendant(type, in: subview) { return match }
        }
        return nil
    }

    // MARK: - Self-check

    /// The managed-agent tile is probed at the tile minimum width
    /// (`TileGeometry.minimumSize(for: .managedAgent).width`) and at two larger
    /// widths, in both appearances.
    static let probeWidths: [Double] = [TileGeometry.minimumSize(for: .managedAgent).width, 640, 900]

    /// Appended after the probe is laid out, so `scrollTranscriptToBottom` runs
    /// against the real probe geometry rather than the fixture's construction-time
    /// frame. Many short prompts, not one long one: enough cards to overflow the
    /// clip view at every probe width (`expectScrolledToBottom(requireOverflow:)`
    /// asserts that), while each line stays *narrower* than the tile. A single
    /// 2000-character line masks the half-width bug entirely — an unpinned column
    /// whose fitting width exceeds the available width still gets clamped to full
    /// width, so the pins-removed witness passed until the prompts were shortened.
    static let scrollWitnessPrompts: [String] = (1...10).map {
        "Scroll witness \($0) — the newest transcript card must stay visible."
    }

    static func runGeometryChecks() throws {
        _ = NSApplication.shared
        // Production pins the app appearance at launch; reproduce it so a probe
        // that failed to set its own appearance could not pass the .aqua pass.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // P5.5 acceptance: the legacy card-stack transcript and its approval dock
        // are deleted; the v2 composition root is gated by
        // `checkLiveV2AgentTileLayout()` below (320/480/640/900 x both themes,
        // fills, clipping, constraints, footer truncation) and the semantic
        // transcript by `checkTranscriptCollectionList()`.
        try checkReusableAgentBlockHost()
        let composerCases = try checkGrowingComposerLayout()
        let choiceCases = try checkChoicePopover()
        try checkAgentTileHeaderShell()
        try checkLiveV2AgentTileLayout()
        let transcriptLiveHosts = try checkTranscriptCollectionList()
        let streamingApplies = try checkIncrementalTranscriptBehavior()
        let proseRows = try checkAssistantProseRenderer()
        let userPromptRows = try checkUserPromptRenderer()
        let codeRows = try checkCodeBlockRenderer()
        let operationRows = try checkToolAndCommandRenderers()
        let exceptionalRows = try checkExceptionalRenderers()
        // P0.4: the inbox measured at the widths it ships at, truncation gated
        // by drawable width against an explicit expected-defect table.
        let sidebarGate = try checkSidebarTruncationGate()
        print(String(
            format: "UIProbeGeometry: sidebar truncation gate measured %d labels at min/default/wide in both appearances; %d truncations, all in the expected table, none healed unrecorded",
            sidebarGate.measured, sidebarGate.truncated
        ))
        print(String(
            format: "UIProbeGeometry: reusable block host identity/reset and 8-dimensional measurement key gated; composer grows through %d width/draft cases with an eight-visual-line cap and stable constraints; custom choice popover gates %d keyboard, disabled, accessibility-state, appearance, and screen-placement cases; live v2 tile gated at 320/480/640/900 in both appearances with footer truncation measured; transcript collection virtualized 10000 rows into %d live hosts while preserving unaffected identity; 5000 streaming deltas coalesced into %d visual apply with anchored/selection-safe scrolling, copy, and ordered accessibility; assistant prose wraps %d semantic rows, user prompt wraps %d semantic rows, fenced code preserves %d exact lines, %d tool/command states preserve scoped disclosure, and %d exceptional states preserve request identity and opaque privacy at 320pt",
            composerCases, choiceCases, transcriptLiveHosts, streamingApplies, proseRows, userPromptRows, codeRows, operationRows, exceptionalRows
        ))
    }

    // MARK: - Sidebar check seam

    private struct SidebarProbeHost {
        let window: NSWindow
        let host: NSView
        let inbox: AgentInboxView
    }

    /// Make the host first and size it before the inbox receives any rows. An
    /// offscreen NSTableView otherwise has no viewport in which to materialize
    /// cells, and a check that only reads the row model would pass vacuously.
    private static func makeSidebarProbeHost(
        width: CGFloat, height: CGFloat, appearanceName: NSAppearance.Name
    ) throws -> SidebarProbeHost {
        guard width > 0, height > 0 else {
            throw fail("sidebar-ux-check: probe host must have nonzero size (width=\(width), height=\(height))")
        }
        guard let appearance = NSAppearance(named: appearanceName) else {
            throw fail("sidebar-ux-check: no NSAppearance named '\(appearanceName.rawValue)'")
        }
        let size = NSSize(width: width, height: height)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = appearance
        window.contentView = host
        // A borderless window may adjust its content view while it is being
        // installed. Re-assert the probe size before Auto Layout gets its first
        // chance to calculate the inbox subtree.
        host.frame = NSRect(origin: .zero, size: size)

        let inbox = AgentInboxView(frame: .zero)
        inbox.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(inbox)
        NSLayoutConstraint.activate([
            inbox.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            inbox.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            inbox.topAnchor.constraint(equalTo: host.topAnchor),
            inbox.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        guard abs(host.bounds.width - width) <= 0.5,
              abs(host.bounds.height - height) <= 0.5,
              inbox.bounds.width > 0, inbox.bounds.height > 0 else {
            throw fail(String(
                format: "sidebar-ux-check@%.0fpt: sized host did not give the inbox a live viewport (host %.1fx%.1f, inbox %.1fx%.1f)",
                width, host.bounds.width, host.bounds.height, inbox.bounds.width, inbox.bounds.height
            ))
        }
        return SidebarProbeHost(window: window, host: host, inbox: inbox)
    }

    // MARK: - P1.1/P1.2/P1.3 — what a row is allowed to paint
    //
    // Tickets: 94/P1.1-remove-row-borders.md, P1.2-interaction-fill-ladder.md,
    //          P1.3-header-shelf-hairlines.md
    //
    // NEGATIVE TESTS OBSERVED RED AGAINST THIS CODE (2026-08-03). Every one was
    // run against the FINAL implementation, then reverted, and the file restored
    // by hash before the green run below.
    //
    //  1 · P1.1 — the border comes back. `AgentInboxCardView.init`:
    //      `layer?.borderWidth = 1`
    //      → `sidebar-ux-check@220pt.NSAppearanceNameAqua: 'openai-codex/gpt-5.6-sol'
    //         paints a 1.0pt row perimeter — a row paints no border in any state (P1.1)`
    //  2 · P1.2 — selection made louder than hover, by resolving it first in
    //      `AgentInboxCardView.surfaceRole`:
    //      → `sidebar-ux-check.ladder.NSAppearanceNameAqua: pointing at a selected
    //         row resolved sidebarSelected — hover is one step louder than selection`
    //  3 · P1.3 — one 1pt literal back, in `InboxBulkActionBar.init`:
    //      → `sidebar-ux-check@220pt.NSAppearanceNameAqua:
    //         /AgentInboxView/InboxBulkActionBar paints a 1.0pt line, past the 0.5pt
    //         hairline — every boundary the sidebar keeps comes from AgentLineRole at
    //         hairline width (P1.3)`
    //  4 · P1.4 — a permanent ring: `focusRing.isHidden = false` in
    //      `AgentInboxCardView.init`:
    //      → `sidebar-ux-check.ladder.NSAppearanceNameAqua: after the pointer left
    //         the list a row still shows its focus ring — the focus treatment must
    //         not outlive focus (P1.4)`
    //  5 · The re-measured census floor really bites:
    //      `minimumSentineledSlots` 141 → 142
    //      → `--ui-probe-check`: `sentinelled 141 layer colours, floor is 142`
    //
    // NOT DISCRIMINATING, recorded so nobody mistakes it for coverage: setting
    // `focusRing.isHidden = false` inside the `hasKeyboardFocus` DIDSET is a no-op
    // and left the gate green — a rebuilt cell is a fresh card whose
    // `hasKeyboardFocus` never changes from its `false` default, so the observer
    // never runs. The ring's default has to be mutated in `init` to break it,
    // which is witness 4.

    /// This gate's hex spelling for a resolved colour, so a fill can be compared
    /// to a token value rather than to another `CGColor` object.
    private static func hex(_ color: CGColor?) -> String {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "nil" }
        func part(_ value: CGFloat) -> String { String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded())) }
        return "#" + part(srgb.redComponent) + part(srgb.greenComponent)
            + part(srgb.blueComponent) + part(srgb.alphaComponent)
    }

    /// The row's fill must BE the fill its resolved role names — and at rest it
    /// must be no fill at all, or exactly the panel showing through.
    ///
    /// Holding the role and the pixel to each other is what makes this stronger
    /// than either half: a row that resolves `.hover` while painting the resting
    /// value, and a row that paints the hover value while resting, are both red.
    private static func expectRowFill(
        _ geometry: AgentInboxRowGeometryForQA, role: SidebarSurfaceRole,
        row: AgentInboxRow, theme: TokenTheme, label: String
    ) throws {
        let painted = hex(geometry.resolvedFill)
        guard role != .resting else {
            // `nil` is the honest answer, and `panel` is the only other one that
            // means "the sidebar's own surface" — the design decision allows
            // either spelling and forbids a third.
            let panel = hex(SidebarSurfaceRole.rowBase.color.cgColor(for: theme))
            guard geometry.resolvedFill == nil || painted == panel else {
                throw fail("\(label): resting row '\(row.title)' paints \(painted), which is neither nothing nor the panel \(panel) — surface is reserved for interaction (P1.1)")
            }
            return
        }
        let expected = hex(role.color.cgColor(for: theme))
        guard painted == expected else {
            throw fail("\(label): '\(row.title)' resolved \(role.rawValue) but paints \(painted), not the role's \(expected) — the fill must come from SidebarSurfaceRole (P1.2)")
        }
    }

    /// Every line and shadow a row paints, held to the two rules: the card's own
    /// perimeter and shadow are ZERO in every state (no row carries state on an
    /// edge), and nothing the row paints is wider than `LineWidth.hairline`.
    private static func expectRowLines(
        _ geometry: AgentInboxRowGeometryForQA, row: AgentInboxRow, label: String
    ) throws {
        for key in ["card.border", "card.shadowOpacity", "focusRing.border"] {
            guard geometry.paintedLines[key] != nil else {
                throw fail("\(label): '\(row.title)' reported no \(key) — the row paint seam stopped covering it")
            }
        }
        for (line, width) in geometry.paintedLines.sorted(by: { $0.key < $1.key }) {
            guard width.isFinite, width >= 0 else {
                throw fail("\(label): '\(row.title)' paints an invalid \(line) of \(width)")
            }
            if line == "card.border" || line == "card.shadowOpacity" {
                guard width == 0 else {
                    throw fail("\(label): '\(row.title)' paints \(line) = \(width) — a row communicates state with a fill and its content, never a border, a shadow or an inset stroke (P1.2)")
                }
                continue
            }
            guard width <= LineWidth.hairline else {
                throw fail("\(label): '\(row.title)' paints \(line) at \(width)pt, past the \(LineWidth.hairline)pt hairline (P1.3)")
            }
        }
    }

    /// P1.3 over the WHOLE live sidebar subtree, not just the rows: no view
    /// paints a line wider than the hairline, and no two views in an
    /// ancestor/descendant relationship both paint one.
    ///
    /// The second half is "one boundary per surface, no nested boxes" as a
    /// structure rather than a style note — a panel border plus a row border, or
    /// a boxed section header inside a bordered list, is what it catches.
    private static func expectHairlineContainment(_ root: NSView, label: String) throws {
        func visit(_ view: NSView, path: String, borderedAncestor: String?) throws {
            let width = Double(view.layer?.borderWidth ?? 0)
            let name = "\(path)/\(String(describing: type(of: view)))"
            // P1.3: a section heading and a paging footer are HEADINGS, not
            // cards — a label, a count, and a disclosure affordance, painted
            // straight onto the list. Anything that is a table cell but not a row
            // must therefore paint no container at all: no fill, no edge.
            if view is NSTableCellView, !(view is AgentInboxRowCell) {
                guard view.layer?.backgroundColor == nil, width == 0 else {
                    throw fail("\(label): \(name) paints a container box (fill \(hex(view.layer?.backgroundColor)), border \(width)pt) — shelf and section headers paint no box (P1.3)")
                }
            }
            var ownsBoundary = borderedAncestor
            if width > 0 {
                guard width <= LineWidth.hairline else {
                    throw fail("\(label): \(name) paints a \(width)pt line, past the \(LineWidth.hairline)pt hairline — every boundary the sidebar keeps comes from AgentLineRole at hairline width (P1.3)")
                }
                if let outer = borderedAncestor {
                    throw fail("\(label): \(name) paints a boundary inside \(outer)'s — one boundary per surface, no nested boxes (P1.3)")
                }
                ownsBoundary = name
            }
            for subview in view.subviews {
                try visit(subview, path: name, borderedAncestor: ownsBoundary)
            }
        }
        try visit(root, path: "", borderedAncestor: nil)
    }

    private static func checkSidebarProbe(
        _ probe: SidebarProbeHost, rows: [AgentInboxRow], width: CGFloat,
        appearanceName: NSAppearance.Name
    ) throws -> (cells: Int, labels: Int, truncated: Int, tiers: Set<RowFitTier>) {
        let label = "sidebar-ux-check@\(Int(width))pt.\(appearanceName.rawValue)"
        let theme: TokenTheme = appearanceName == .darkAqua ? .dark : .light
        // Size the whole subtree first. Applying rows before this line is the
        // offscreen-materialization bug this leg exists to prevent.
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.reload(rows: rows)
        probe.inbox.layoutForQA()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.layoutForQA()

        let cells = probe.inbox.qaMaterializedRowCells
        guard !cells.isEmpty else {
            throw fail("\(label): no row cells materialized")
        }
        guard cells.count == rows.count,
              probe.inbox.qaMaterializedRowCellCount == rows.count else {
            throw fail("\(label): materialized \(cells.count) row cells for \(rows.count) corpus rows")
        }
        // Negative witness (2026-08-03): changing the first `==` to `>` made
        // `--sidebar-ux-check` exit 1 at the exact message
        // `sidebar-ux-check@220pt.NSAppearanceNameAqua: materialized 7 row cells for 7 corpus rows`.
        // The source was restored by hash before the green run.
        guard cells.allSatisfy({ $0.isDescendant(of: probe.inbox) && $0.window === probe.window }) else {
            throw fail("\(label): a QA row cell is not part of the live inbox window tree")
        }

        let geometries = probe.inbox.qaRowGeometriesForQA
        guard geometries.count == cells.count else {
            throw fail("\(label): geometry seam returned \(geometries.count) entries for \(cells.count) live row cells")
        }
        var geometryByID: [UUID: AgentInboxRowGeometryForQA] = [:]
        for geometry in geometries {
            guard let id = geometry.agentID else {
                throw fail("\(label): a materialized row geometry has no agent identity")
            }
            guard geometryByID.updateValue(geometry, forKey: id) == nil else {
                throw fail("\(label): duplicate live geometry for agent \(id.uuidString)")
            }
        }
        let expectedIDs = Set(rows.map(\.id))
        guard Set(geometryByID.keys) == expectedIDs else {
            throw fail("\(label): live row geometry ids do not match the corpus")
        }
        for cell in cells {
            guard let id = cell.qaAgentID, let geometry = geometryByID[id],
                  let variant = geometry.variant else {
                throw fail("\(label): a live row cell has no resolved variant identity")
            }
            let classVariant: RowVariant = cell is AgentInboxSlimCellView ? .slim : .card
            guard classVariant == variant else {
                throw fail("\(label): live cell for \(id.uuidString) resolved as \(variant.rawValue) but materialized as \(classVariant.rawValue)")
            }
        }

        var labelCount = 0
        var truncatedCount = 0
        var paintedStates = Set<InboxState>()
        var observedTiers = Set<RowFitTier>()
        for row in rows {
            guard let geometry = geometryByID[row.id],
                  geometry.state == row.state,
                  geometry.variant == row.variant else {
                throw fail("\(label): live row \(row.id.uuidString) lost its state or resolved variant")
            }
            // Ticket: docs/38-tickets/94-sidebar-native-ux/P1.1-remove-row-borders.md
            //
            // THE ASSERTION IS FLIPPED HERE, and the flip is the packet. P0.2
            // asserted `borderWidth >= 0` and `fill.alpha > 0` — it observed the
            // grey box around every idle row rather than blessing its removal.
            // Now a row paints NO perimeter in any state and NOTHING at rest, so
            // the same two accessors assert the opposite over the same live tree
            // in both appearances: a reintroduced border or an opaque resting
            // card fails exactly the assertion the removal satisfies.
            guard let borderWidth = geometry.paintedBorderWidth,
                  borderWidth.isFinite, borderWidth == 0 else {
                throw fail("\(label): '\(row.title)' paints a \(geometry.paintedBorderWidth.map { "\($0)pt" } ?? "missing") row perimeter — a row paints no border in any state (P1.1)")
            }
            guard let role = geometry.surfaceRole else {
                throw fail("\(label): '\(row.title)' resolved no SidebarSurfaceRole — a row's fill must come from the ladder, not from a literal")
            }
            try expectRowFill(geometry, role: role, row: row, theme: theme, label: label)
            // P1.2 step 4: no row communicates state through a border, a shadow
            // or an inset stroke — and P1.3: no sidebar line exceeds the
            // hairline. Both are measurements over the same dictionary.
            try expectRowLines(geometry, row: row, label: label)
            paintedStates.insert(row.state)

            let expectedElements: Set<String>
            switch row.variant {
            case .card:
                expectedElements = ["cell", "card", "project", "title", "state", "elapsed", "meta", "branch"]
            case .slim:
                expectedElements = ["cell", "card", "glyph", "title", "branch", "time"]
            }
            guard Set(geometry.elementFrames.keys) == expectedElements else {
                throw fail("\(label): '\(row.title)' did not expose the live \(row.variant.rawValue) element frames")
            }
            for (element, frame) in geometry.elementFrames {
                guard frame.width.isFinite, frame.height.isFinite,
                      frame.width >= 0, frame.height >= 0 else {
                    throw fail("\(label): '\(row.title)' has an invalid \(element) frame \(frame)")
                }
            }
            guard let cellFrame = geometry.elementFrames["cell"],
                  cellFrame.width > 0, cellFrame.height > 0,
                  let cardFrame = geometry.elementFrames["card"],
                  cardFrame.width > 0, cardFrame.height > 0 else {
                throw fail("\(label): '\(row.title)' has no painted cell/card frame")
            }

            let expectedLabels: Set<String> = row.variant == .card
                ? ["project", "title", "state", "elapsed", "meta", "branch"]
                : ["glyph", "title", "branch", "time"]
            guard Set(geometry.labels.map(\.element)) == expectedLabels else {
                throw fail("\(label): '\(row.title)' did not expose every live label")
            }
            for measurement in geometry.labels {
                labelCount += 1
                guard let font = measurement.font else {
                    throw fail("\(label): '\(row.title)' label \(measurement.element) has no live font")
                }
                let measuredNeed = Double(
                    ceil((measurement.text as NSString).size(withAttributes: [.font: font]).width)
                ) + Metrics.cellTextInset
                guard abs(measurement.neededWidth - measuredNeed) <= 0.01 else {
                    throw fail("\(label): '\(row.title)' label \(measurement.element) reported need \(measurement.neededWidth), measured \(measuredNeed) including the \(Metrics.cellTextInset)pt cell inset")
                }
                guard measurement.drawableWidth.isFinite,
                      measurement.drawableWidth >= 0,
                      abs(measurement.drawableWidth - Double(measurement.frame.width)) <= 0.01 else {
                    throw fail("\(label): '\(row.title)' label \(measurement.element) reported drawable width \(measurement.drawableWidth), but its live frame is \(measurement.frame.width)")
                }
                if !measurement.isHidden, !measurement.text.isEmpty {
                    guard measurement.frame.width > 0, measurement.frame.height > 0 else {
                        throw fail("\(label): visible label \(measurement.element) on '\(row.title)' has no drawable frame")
                    }
                    if measurement.drawableWidth + 0.5 < measurement.neededWidth {
                        truncatedCount += 1
                    }
                }
            }
            // P2.1/P2.2, over the same live geometry: the three bands, the
            // recorded sacrifice ladder, and the tier the row resolved to.
            if row.variant == .card {
                try expectRowBandsAndSacrificeOrder(geometry, row: row, label: label)
                if let tier = geometry.fitTier { observedTiers.insert(tier) }
            }
        }
        guard paintedStates == Set(InboxState.allCases) else {
            throw fail("\(label): paint seam covered \(paintedStates.count) states, expected every InboxState")
        }
        // P1.3, over the whole subtree at this width and appearance.
        try expectHairlineContainment(probe.inbox, label: label)
        return (cells.count, labelCount, truncatedCount, observedTiers)
    }

    // MARK: - P2.1/P2.2 — three bands, one recorded order, one measured tier
    //
    // Tickets: 94/P2.1-title-line-ownership.md, P2.2-measured-fit-tiers.md
    //
    // Four things are asserted here, over the LIVE card at every gated width in
    // both appearances, because each of the four is a way the other three could
    // be satisfied and the row still be wrong:
    //
    //  1 · BAND MEMBERSHIP. The name is on a line of its OWN — strictly below
    //      the project chip, the state and the elapsed column, strictly above the
    //      role/rollup line and the branch. A row that merely raised the title's
    //      priority while leaving it on the headline would pass a truncation
    //      count and fail this.
    //  2 · THE LANE IS THE LINE. On a row with no children the title's drawing
    //      lane spans the card's whole text column. This is what "owns its line"
    //      MEANS; without it the name could be given a line and then handed a
    //      third of it.
    //  3 · THE RECORDED SACRIFICE ORDER, as a strict ladder of the LIVE
    //      compression resistances, read off the labels. Priorities are the
    //      mechanism the order is implemented with, so asserting them is
    //      asserting the decision — and a chip quietly restored to AppKit's
    //      default 750 is red here even at a width where nothing truncates.
    //  4 · THE TIER AND WHAT IT DROPPED, held to each other, plus the
    //      relocation: a column a tier stopped drawing is in the cell's
    //      accessibility label, because a VoiceOver user has no width problem.

    /// The elements P2.1 puts on band 1, band 3, and the two that may never be
    /// dropped. Named here rather than inline so the two directions of the band
    /// assertion cannot drift apart.
    private static let sidebarMetaBandElements = ["project", "state", "elapsed"]
    private static let sidebarDetailBandElements = ["meta", "branch"]

    private static func expectRowBandsAndSacrificeOrder(
        _ geometry: AgentInboxRowGeometryForQA, row: AgentInboxRow, label: String
    ) throws {
        var byElement: [String: AgentInboxLabelGeometryForQA] = [:]
        for measurement in geometry.labels { byElement[measurement.element] = measurement }
        guard let title = byElement["title"], !title.isHidden, title.frame.width > 0 else {
            throw fail("\(label): '\(row.title)' draws no name — the row's subject is its name (P2.1)")
        }

        // 1 · BAND MEMBERSHIP. The cell is an unflipped `NSView`, so a LARGER y is
        // further UP the card: band 1 (meta) sits at the largest y, the name band
        // under it, band 3 under that. Compared on vertical CENTRES with a whole
        // point of clearance, so two labels that merely differ by an ascent cannot
        // satisfy it.
        for element in sidebarMetaBandElements {
            guard let above = byElement[element], !above.isHidden, above.frame.width > 0 else { continue }
            guard title.frame.midY < above.frame.midY - 1 else {
                throw fail("\(label): '\(row.title)' draws \(element) on or under the name's line (name midY \(title.frame.midY), \(element) midY \(above.frame.midY)) — the name owns a line of its own, with the meta band above it (P2.1)")
            }
        }
        for element in sidebarDetailBandElements {
            guard let below = byElement[element], !below.isHidden, below.frame.width > 0 else { continue }
            guard title.frame.midY > below.frame.midY + 1 else {
                throw fail("\(label): '\(row.title)' draws \(element) on or above the name's line (name midY \(title.frame.midY), \(element) midY \(below.frame.midY)) — the detail band is below the name (P2.1)")
            }
        }

        // 2 · THE LANE IS THE LINE, on a row that draws no triangle. "Draws no
        // triangle" is read off the geometry — the name starts at the text
        // column's own leading edge — rather than off the row model, so a
        // disclosure control that was hidden but still taking room fails here.
        //
        // MEASURED IN ALIGNMENT-RECT TERMS, which is the only way this arithmetic
        // closes: Auto Layout pins an `NSTextField`'s ALIGNMENT RECT, and a label's
        // alignment rect is inset 2pt on each side of its frame — exactly the
        // `Metrics.cellTextInset` the whole gate is built around. So a name pinned
        // to both edges of a 196pt text column reports a 200pt frame, and
        // subtracting the inset is what turns the frame back into the lane. (It is
        // also why `neededWidth` adds the same 4: both sides of the comparison then
        // speak about the same rectangle.)
        if let card = geometry.elementFrames["card"] {
            let columnLeading = Double(card.minX) + Inset.card.left - Metrics.cellTextInset / 2
            let drawsTriangle = Double(title.frame.minX) > columnLeading + 0.5
            if !drawsTriangle {
                let lane = title.drawableWidth - Metrics.cellTextInset
                let wanted = Double(card.width) - Inset.card.horizontal
                guard abs(lane - wanted) <= 0.5 else {
                    throw fail(String(
                        format: "%@: '%@' draws no triangle, so its name's lane is the whole text column — got %.1fpt of %.1fpt (name x %.1f…%.1f, card x %.1f…%.1f) (P2.1)",
                        label, row.title, lane, wanted,
                        title.frame.minX, title.frame.maxX, card.minX, card.maxX))
                }
            }
        }

        // 3 · THE RECORDED SACRIFICE ORDER, as live priorities:
        //     project < branch < meta < title < state == elapsed == required.
        let ladder = ["project", "branch", "meta", "title", "state"]
        var previous: (element: String, priority: Double)?
        for element in ladder {
            guard let measurement = byElement[element] else {
                throw fail("\(label): '\(row.title)' exposes no \(element) label to read a priority off")
            }
            if let previous {
                guard previous.priority < measurement.compressionResistance else {
                    throw fail("\(label): '\(row.title)' resists compression \(previous.element)=\(previous.priority) then \(element)=\(measurement.compressionResistance) — the recorded sacrifice order is caption/project chip → branch → metrics → role/rollup → NAME, and it is enforced as a strict ladder (P2.1)")
                }
            }
            previous = (element, measurement.compressionResistance)
        }
        guard let state = byElement["state"], let elapsed = byElement["elapsed"],
              state.compressionResistance == Double(NSLayoutConstraint.Priority.required.rawValue),
              elapsed.compressionResistance == Double(NSLayoutConstraint.Priority.required.rawValue) else {
            throw fail("\(label): '\(row.title)' lets the state word or the elapsed column be compressed — the one word saying what an agent is doing is never half a word, and a duration is never half a duration (P2.1)")
        }
        guard title.compressionResistance
            == Double(AgentInboxCellView.nameCompressionResistance.rawValue) else {
            throw fail("\(label): '\(row.title)' resists compression at \(title.compressionResistance), not the \(AgentInboxCellView.nameCompressionResistance.rawValue) the name is pinned at (P2.1)")
        }

        // 4 · THE TIER, AND WHAT IT DROPPED.
        guard let tier = geometry.fitTier else {
            throw fail("\(label): '\(row.title)' is a card and resolved no measured-fit tier (P2.2)")
        }
        let project = byElement["project"]
        if row.projectName != nil {
            guard (project?.isHidden == false) == tier.drawsProject else {
                throw fail("\(label): '\(row.title)' resolved \(tier.rawValue) but its project chip is \(project?.isHidden == true ? "hidden" : "drawn") — a tier's sacrifice is what it actually stopped drawing (P2.2)")
            }
        }
        if row.elapsed != nil {
            guard (elapsed.isHidden == false) == tier.drawsElapsed else {
                throw fail("\(label): '\(row.title)' resolved \(tier.rawValue) but its elapsed column is \(elapsed.isHidden ? "hidden" : "drawn") — a tier's sacrifice is what it actually stopped drawing (P2.2)")
            }
        }
        // NEVER a tier's sacrifice, at any width.
        guard !title.isHidden else {
            throw fail("\(label): a tier hid '\(row.title)' — the name is never a tier's sacrifice (P2.2)")
        }
        if row.label != nil {
            guard state.isHidden == false else {
                throw fail("\(label): a tier hid the state word on '\(row.title)' — the state is never a tier's sacrifice (P2.2)")
            }
        }
        // RELOCATED, not lost.
        let spoken = geometry.accessibilityLabel ?? ""
        guard spoken.contains(row.title) else {
            throw fail("\(label): the cell for '\(row.title)' does not say its own name to VoiceOver")
        }
        if let projectName = row.projectName, project?.isHidden == true {
            guard spoken.contains(projectName) else {
                throw fail("\(label): '\(row.title)' dropped its project chip at \(tier.rawValue) without folding '\(projectName)' into the accessibility label — a dropped column is relocated, never deleted (P2.2)")
            }
        }
        if let elapsedText = AgentInboxCellView.elapsedText(row.elapsed), elapsed.isHidden {
            guard spoken.contains(elapsedText) else {
                throw fail("\(label): '\(row.title)' dropped its elapsed column at \(tier.rawValue) without folding '\(elapsedText)' into the accessibility label — a dropped column is relocated, never deleted (P2.2)")
            }
        }
    }

    /// P2.2's tier ladder as ARITHMETIC — its boundaries, the name's part in it,
    /// and its monotonicity. The other half of the ladder is asserted on live
    /// cells: `expectRowBandsAndSacrificeOrder` holds every card row's resolved
    /// tier to what it actually stopped drawing, and `runSidebarUXChecks` requires
    /// all three tiers to be REACHED across the gated widths, so a tier no width
    /// resolves cannot sit here looking implemented.
    ///
    /// EVERY BOUNDARY BELOW IS DERIVED FROM A MEASUREMENT, never typed. The widths
    /// handed to `fitTier` are the needs the fixture itself measures, plus or minus
    /// one point — so this leg cannot be satisfied by a threshold that happens to
    /// agree with today's fonts, and a P1.4 type move re-derives it instead of
    /// falsifying it.
    private static func checkSidebarFitTierLadder() throws -> Int {
        var asserted = 0
        let label = "sidebar-ux-check.fitTier"

        // A0 · THE FLOOR MUST BE ABLE TO DRAW ITS OWN GUARANTEE.
        //
        // `AgentInboxCellView.minimumTextWidth(role)` promises that a squeezed
        // label still draws four characters. Before P2.2 it measured `"0000"` with
        // no cell inset, so the promise was exactly the width of the STRING and
        // AppKit elided it at the floor — the guaranteed minimum ellipsised its own
        // content, which is a promise that cannot be kept. Asserted against
        // `measuredTextWidth`, the same arithmetic the QA seam reports as
        // `neededWidth` and the truncation gate compares against, so the floor and
        // the gate cannot disagree about what a string needs.
        for role in [TextRole.title, .label, .caption, .captionMono] {
            let floor = AgentInboxCellView.minimumTextWidth(role)
            let needed = AgentInboxCellView.measuredTextWidth("0000", role)
            guard floor >= needed else {
                throw fail(String(format: "%@: the %@ floor guarantees %.1fpt but drawing \"0000\" in it needs %.1fpt including the %.1fpt cell inset — a floor that elides its own content is not a floor (P2.2)",
                                  label, String(describing: role), floor, needed, Metrics.cellTextInset))
            }
            asserted += 1
        }

        // A · THE ARITHMETIC. A short name, so the meta band is what decides.
        let needs = AgentInboxCellView.RowFitNeeds(
            project: AgentInboxCellView.measuredTextWidth("continuum", .caption),
            state: AgentInboxCellView.measuredTextWidth("Working", .label),
            elapsed: AgentInboxCellView.measuredTextWidth("162h21m", .captionMono),
            title: AgentInboxCellView.measuredTextWidth("pi", .title),
            disclosure: 0)
        let needsFull = needs.metaBandNeed(elapsed: true, project: true)
        let needsAbbreviated = needs.metaBandNeed(elapsed: false, project: true)
        let needsCaption = needs.metaBandNeed(elapsed: false, project: false)
        guard needs.nameBandNeed < needsCaption else {
            throw fail("\(label): the fixture's name is wider than its tightest meta band, so this leg would be measuring the name rather than the ladder")
        }
        guard needsFull > needsAbbreviated, needsAbbreviated > needsCaption else {
            throw fail(String(format: "%@: the three meta-band needs are not strictly decreasing (%.1f, %.1f, %.1f) — a tier that costs nothing is not a sacrifice", label, needsFull, needsAbbreviated, needsCaption))
        }
        let ladder: [(available: Double, tier: RowFitTier)] = [
            (needsFull, .full),
            (needsFull - 1, .abbreviated),
            (needsAbbreviated, .abbreviated),
            (needsAbbreviated - 1, .captionHidden),
            (needsCaption, .captionHidden),
        ]
        for step in ladder {
            let resolved = AgentInboxCellView.fitTier(available: step.available, needs: needs)
            guard resolved == step.tier else {
                throw fail(String(format: "%@: %.1fpt of room resolved %@, wanted %@ — the tier is chosen by comparing measured need against available width (P2.2)", label, step.available, resolved.rawValue, step.tier.rawValue))
            }
            asserted += 1
        }
        // THE NAME IS PART OF THE TEST: a row whose own name does not fit is at
        // the tightest tier however comfortably its metadata would have fitted.
        let longNamed = AgentInboxCellView.RowFitNeeds(
            project: needs.project, state: needs.state, elapsed: needs.elapsed,
            title: needsFull * 2, disclosure: 0)
        guard AgentInboxCellView.fitTier(available: needsFull, needs: longNamed) == .captionHidden else {
            throw fail("\(label): a row too narrow for its own name resolved a tier above the tightest — the name can only be found elided on a row that has already dropped everything a tier may drop (P2.1/P2.2)")
        }
        asserted += 1
        // Monotone: shrinking the room never LOOSENS the tier.
        var last = RowFitTier.full
        for step in stride(from: needsFull + 20, through: 1, by: -1) {
            let resolved = AgentInboxCellView.fitTier(available: step, needs: needs)
            guard RowFitTier.allCases.firstIndex(of: resolved)!
                >= RowFitTier.allCases.firstIndex(of: last)! else {
                throw fail(String(format: "%@: %.0fpt resolved %@ after %@ at a wider width — the ladder must be monotone", label, step, resolved.rawValue, last.rawValue))
            }
            last = resolved
        }
        asserted += 1

        // B · THE MIDDLE RUNG, ON A LIVE ROW, at a width taken from that row's own
        // measurements.
        //
        // WHY THIS LEG EXISTS. Across 220/280/320 the corpus reaches `full` and
        // `captionHidden` and never `abbreviated`, and the reason is a property of
        // the corpus rather than of the ladder: `abbreviated` is the window where
        // the meta band overruns its line by less than the elapsed column is wide,
        // which needs a project name of MIDDLING length. The P0.3 corpus has
        // `continuum` (nine characters, fits at every width) and one 66-character
        // monster (which busts the band with or without the elapsed column, so it
        // lands at `captionHidden`), and nothing between — and this packet may not
        // add a fixture, because the corpus is indexed by position and every
        // `rowN` key in the truncation table would shift. So the rung is witnessed
        // on a REAL row at a DERIVED width instead: the width below is computed
        // from the row's own measured needs, never typed, and the assertion is
        // that the live cell drops its elapsed column and keeps its project chip.
        let corpus = LabFixtures.inboxDefectRows()
        var middle: (row: AgentInboxRow, available: Double)?
        for candidate in corpus where candidate.variant == .card {
            let candidateNeeds = AgentInboxCellView.RowFitNeeds(
                project: AgentInboxCellView.measuredTextWidth(candidate.projectName ?? "", .caption),
                state: AgentInboxCellView.measuredTextWidth(candidate.label ?? "", .label),
                elapsed: AgentInboxCellView.measuredTextWidth(
                    AgentInboxCellView.elapsedText(candidate.elapsed) ?? "", .captionMono),
                title: AgentInboxCellView.measuredTextWidth(candidate.title, .title),
                disclosure: 0)
            let ceiling = candidateNeeds.metaBandNeed(elapsed: true, project: true)
            let floor = max(candidateNeeds.metaBandNeed(elapsed: false, project: true),
                            candidateNeeds.nameBandNeed)
            guard floor < ceiling else { continue }
            middle = (candidate, ((floor + ceiling) / 2).rounded(.down))
            break
        }
        guard let middle else {
            throw fail("\(label): no corpus card row has a width window in which dropping the elapsed column is enough — the middle rung of the ladder cannot be witnessed on a live row")
        }
        let rowPitch = AgentInboxView.rowHeight + Space.s
        let probeHeight = CGFloat(
            (Double(corpus.count + 2) * rowPitch + AgentInboxView.scopeControlHeight + 160).rounded(.up)
        )
        let probe = try makeSidebarProbeHost(
            width: CGFloat((middle.available + Inset.card.horizontal).rounded(.up)),
            height: probeHeight, appearanceName: .aqua)
        probe.inbox.clock = { LabFixtures.inboxNow }
        probe.inbox.toggleShelf()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.reload(rows: corpus)
        probe.inbox.layoutForQA()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.layoutForQA()
        guard let geometry = probe.inbox.qaRowGeometriesForQA.first(where: { $0.agentID == middle.row.id }) else {
            throw fail("\(label): '\(middle.row.title)' did not materialize at the derived middle-rung width")
        }
        guard geometry.fitTier == .abbreviated else {
            throw fail(String(format: "%@: '%@' resolved %@ at %.1fpt of text column, between its %.1fpt full need and its %.1fpt need without the elapsed column — the middle rung must be reachable on a live row (P2.2)",
                              label, middle.row.title, geometry.fitTier?.rawValue ?? "nil",
                              middle.available,
                              needs.metaBandNeed(elapsed: true, project: true),
                              needs.metaBandNeed(elapsed: false, project: true)))
        }
        var byElement: [String: AgentInboxLabelGeometryForQA] = [:]
        for measurement in geometry.labels { byElement[measurement.element] = measurement }
        guard byElement["elapsed"]?.isHidden == true, byElement["project"]?.isHidden == false else {
            throw fail("\(label): the abbreviated rung must drop the elapsed column and KEEP the project chip — elapsed hidden \(byElement["elapsed"]?.isHidden ?? false), project hidden \(byElement["project"]?.isHidden ?? true) (P2.2)")
        }
        guard let elapsedText = AgentInboxCellView.elapsedText(middle.row.elapsed),
              geometry.accessibilityLabel?.contains(elapsedText) == true else {
            throw fail("\(label): the abbreviated rung dropped the elapsed column without folding it into the accessibility label (P2.2)")
        }
        asserted += 1

        return asserted
    }

    // MARK: - P1.2/P1.4 — the interaction ladder and the focus ring
    //
    // Tickets: 94/P1.2-interaction-fill-ladder.md, P1.4-focus-ring-and-floors.md
    //
    // Four states, measured off the LIVE row rather than off the token table:
    // resting (unfilled), multi-selected, hovered, route-active — with SELECTION
    // QUIETER THAN HOVER, because hover is transient pointer feedback and
    // selection is a resting state you park on. The ordering is asserted as an
    // emphasis measurement against the resting panel, in both appearances, so it
    // cannot be satisfied by naming the roles in the right order and painting
    // them in the wrong one.

    /// One row's paint, as this gate reads it back.
    private struct LadderReading {
        let role: SidebarSurfaceRole
        let fill: String
        /// Contrast of the painted fill against the resting panel — the number
        /// `SidebarTokens.rowEmphasisRatio` predicts, measured off the pixel.
        let emphasis: Double
        let isFocusRingVisible: Bool
        let lines: [String: Double]
    }

    private static func chipColor(_ color: CGColor?) -> ChipColor? {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        return ChipColor(r: srgb.redComponent, g: srgb.greenComponent, b: srgb.blueComponent)
    }

    private static func ladderReading(
        _ inbox: AgentInboxView, agent: UUID, theme: TokenTheme, label: String
    ) throws -> LadderReading {
        // An offscreen probe window defers the incremental reload `redraw` asks
        // for, so the cells in the tree can predate the input change. Measured:
        // without this the leg failed with `a multi-selected pair resolved
        // sidebarResting/sidebarResting` on a table whose `selectedRowIndexes`
        // really did hold two rows. `rebuildRowsForQA` forces the rebuild the
        // screen would have got, without emptying the selection.
        inbox.rebuildRowsForQA()
        let matching = inbox.qaRowGeometriesForQA.filter { $0.agentID == agent }
        guard matching.count == 1, let geometry = matching.first else {
            throw fail("\(label): agent \(agent.uuidString) has \(matching.count) live rows to measure, expected exactly 1 — a retired cell is still in the tree and a stale reading is what this would report")
        }
        guard let role = geometry.surfaceRole else {
            throw fail("\(label): agent \(agent.uuidString) resolved no SidebarSurfaceRole")
        }
        let panel = SidebarSurfaceRole.rowBase.color.resolved(for: theme)
        // An unfilled row IS the panel — that is the identity the role declares,
        // so the measurement carries the panel through rather than inventing a
        // value for "no fill".
        let painted = chipColor(geometry.resolvedFill) ?? panel
        return LadderReading(
            role: role,
            fill: hex(geometry.resolvedFill),
            emphasis: WCAGContrast.ratio(painted, panel),
            isFocusRingVisible: geometry.isFocusRingVisible,
            lines: geometry.paintedLines
        )
    }

    /// No row anywhere in the list is lit or ringed. The "nothing is left behind"
    /// assertion, used after an exit, a scroll, a re-render and a deactivation.
    private static func expectNothingLit(_ inbox: AgentInboxView, why: String, label: String) throws {
        inbox.layoutForQA()
        for geometry in inbox.qaRowGeometriesForQA {
            guard geometry.surfaceRole == .resting || geometry.surfaceRole == .selected else {
                throw fail("\(label): after \(why) a row is still on \(geometry.surfaceRole?.rawValue ?? "nil") — no row may be left lit (P1.2)")
            }
            guard !geometry.isFocusRingVisible else {
                throw fail("\(label): after \(why) a row still shows its focus ring — the focus treatment must not outlive focus (P1.4)")
            }
        }
        guard inbox.hoveredAgentIdForQA == nil else {
            throw fail("\(label): after \(why) the list still believes agent \(inbox.hoveredAgentIdForQA!.uuidString) is hovered")
        }
    }

    private static func checkSidebarInteractionLadder(rows: [AgentInboxRow], probeHeight: CGFloat) throws -> Int {
        var asserted = 0
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp?.appearance = NSAppearance(named: appearanceName)
            let theme: TokenTheme = appearanceName == .darkAqua ? .dark : .light
            let label = "sidebar-ux-check.ladder.\(appearanceName.rawValue)"
            let probe = try makeSidebarProbeHost(
                width: CGFloat(WorkspaceSidebarConfig.defaultWidth),
                height: probeHeight, appearanceName: appearanceName
            )
            probe.inbox.clock = { LabFixtures.inboxNow }
            probe.inbox.toggleShelf()
            probe.host.layoutSubtreeIfNeeded()
            probe.inbox.reload(rows: rows)
            probe.inbox.layoutForQA()

            let ids = probe.inbox.rowIdsForQA
            guard ids.count >= 2 else { throw fail("\(label): the ladder needs at least two rows") }
            let first = ids[0]
            let second = ids[1]

            // 1 · At rest, unfilled.
            let resting = try ladderReading(probe.inbox, agent: first, theme: theme, label: label)
            guard resting.role == .resting, resting.fill == "nil" else {
                throw fail("\(label): an untouched row is on \(resting.role.rawValue) painting \(resting.fill) — a row at rest is unfilled (P1.1)")
            }
            asserted += 1

            // 2 · Hover, and hover CLEARS on exit.
            guard probe.inbox.hoverRowForQA(id: first) else {
                throw fail("\(label): the first row must be hoverable")
            }
            let hovered = try ladderReading(probe.inbox, agent: first, theme: theme, label: label)
            guard hovered.role == .hover else {
                throw fail("\(label): a hovered row resolved \(hovered.role.rawValue), not hover")
            }
            _ = probe.inbox.hoverRowForQA(id: nil)
            try expectNothingLit(probe.inbox, why: "the pointer left the list", label: label)
            asserted += 1

            // 3 · Multi-selection. Two rows selected are two rows FILLED — the
            // outline they used to take is gone.
            guard probe.inbox.selectRowsForQA(ids: [first, second]) else {
                throw fail("\(label): two rows must be selectable together")
            }
            // Not vacuous: the pair must really BE selected, or the fill
            // assertion below would be measuring two resting rows.
            guard probe.inbox.selectedRowCountForQA == 2 else {
                throw fail("\(label): the probe selected \(probe.inbox.selectedRowCountForQA) rows, not 2 — multiple selection is off or the ids are not on screen")
            }
            let selected = try ladderReading(probe.inbox, agent: first, theme: theme, label: label)
            let selectedSecond = try ladderReading(probe.inbox, agent: second, theme: theme, label: label)
            guard selected.role == .selected, selectedSecond.role == .selected else {
                throw fail("\(label): a multi-selected pair resolved \(selected.role.rawValue)/\(selectedSecond.role.rawValue), not selected")
            }
            asserted += 1

            // 4 · Hover OUTRANKS selection: the row you are pointing at always
            // reads above a parked selection, which is what "selection is
            // quieter than hover" means on screen rather than in a table.
            _ = probe.inbox.hoverRowForQA(id: first)
            let hoveredSelected = try ladderReading(probe.inbox, agent: first, theme: theme, label: label)
            guard hoveredSelected.role == .hover else {
                throw fail("\(label): pointing at a selected row resolved \(hoveredSelected.role.rawValue) — hover is one step louder than selection")
            }
            _ = probe.inbox.hoverRowForQA(id: nil)
            asserted += 1

            // 5 · Route-active is the loudest, and it is distinguishable from a
            // multi-selected row rather than merely from a resting one: both
            // rows below are SELECTED, and only one has its tile open.
            // `openAgentId` IS route-active (see its note on `AgentInboxView`),
            // and setting it re-filters and re-renders the list — which empties
            // the table's selection. So the pair is re-selected AFTER it, and the
            // assertion below is then genuinely about two SELECTED rows, one of
            // which also has its tile open.
            probe.inbox.openAgentId = first
            guard probe.inbox.selectRowsForQA(ids: [first, second]) else {
                throw fail("\(label): the pair must re-select once a tile is open")
            }
            let active = try ladderReading(probe.inbox, agent: first, theme: theme, label: label)
            let stillSelected = try ladderReading(probe.inbox, agent: second, theme: theme, label: label)
            guard active.role == .active, stillSelected.role == .selected else {
                throw fail("\(label): route-active/multi-selected resolved \(active.role.rawValue)/\(stillSelected.role.rawValue)")
            }
            guard active.fill != stillSelected.fill else {
                throw fail("\(label): the route-active row and a multi-selected row both paint \(active.fill) — the two must be distinguishable from EACH OTHER (P1.2)")
            }
            asserted += 1

            // 6 · Four distinct fills, and the ORDERING by measurement.
            let ladder = [resting, selected, hovered, active]
            let fills = Set(ladder.map(\.fill))
            guard fills.count == ladder.count else {
                throw fail("\(label): the four states paint \(fills.count) distinct fills (\(fills.sorted().joined(separator: ", "))) — all four must be distinguishable by measured fill")
            }
            guard resting.emphasis == 1.0 else {
                throw fail(String(format: "%@: a resting row measures %.3f:1 against the panel, not the 1.000 identity", label, resting.emphasis))
            }
            guard selected.emphasis < hovered.emphasis else {
                throw fail(String(
                    format: "%@: selected measures %.3f:1 and hover %.3f:1 against the panel — SELECTION MUST STAY QUIETER THAN HOVER (P1.2)",
                    label, selected.emphasis, hovered.emphasis))
            }
            guard hovered.emphasis < active.emphasis else {
                throw fail(String(
                    format: "%@: hover measures %.3f:1 and route-active %.3f:1 — the open agent's row is the loudest step",
                    label, hovered.emphasis, active.emphasis))
            }
            // And the painted ladder must agree with the token ladder P0.5 pinned,
            // so a fill cannot drift away from the role it claims.
            for reading in [selected, hovered, active] {
                let predicted = SidebarTokens.rowEmphasisRatio(reading.role, theme: theme)
                guard abs(reading.emphasis - predicted) <= 0.01 else {
                    throw fail(String(
                        format: "%@: %@ measures %.3f:1 on screen but %.3f:1 in the token table",
                        label, reading.role.rawValue, reading.emphasis, predicted))
                }
            }
            asserted += 1

            // 7 · No state anywhere in the ladder is carried by an edge.
            for reading in ladder {
                guard reading.lines["card.border"] == 0, reading.lines["card.shadowOpacity"] == 0 else {
                    throw fail("\(label): the \(reading.role.rawValue) state paints border \(reading.lines["card.border"] ?? -1) / shadow \(reading.lines["card.shadowOpacity"] ?? -1) — no row communicates state through a border, a shadow or an inset stroke (P1.2)")
                }
                guard reading.isFocusRingVisible == false else {
                    throw fail("\(label): the \(reading.role.rawValue) state shows a focus ring without the keyboard — focus is not a fill state (P1.4)")
                }
            }
            asserted += 1

            // 8 · The FOCUS RING. Both rows are selected; only one has the
            // keyboard, so a keyboard user can tell which row Return will act on.
            probe.inbox.openAgentId = nil
            guard probe.inbox.selectRowsForQA(ids: [first, second]) else {
                throw fail("\(label): the pair must re-select for the focus leg")
            }
            // The ring goes on AFTER the pair is selected, and it moves no
            // selection — so what the two readings below differ by is exactly
            // the keyboard, on two rows that are otherwise in the same state.
            guard probe.inbox.focusRowByKeyboardForQA(id: second) else {
                throw fail("\(label): the second row must take keyboard focus")
            }
            let focused = try ladderReading(probe.inbox, agent: second, theme: theme, label: label)
            let merelySelected = try ladderReading(probe.inbox, agent: first, theme: theme, label: label)
            guard focused.isFocusRingVisible, !merelySelected.isFocusRingVisible else {
                throw fail("\(label): keyboard focus is not distinguishable from selection — ring visible focused=\(focused.isFocusRingVisible) selected=\(merelySelected.isFocusRingVisible) (P1.4)")
            }
            guard focused.role == merelySelected.role else {
                throw fail("\(label): keyboard focus changed the row's FILL (\(focused.role.rawValue) vs \(merelySelected.role.rawValue)) — focus is a temporary ring, selection is the resting fill")
            }
            guard focused.lines["focusRing.border"] == LineWidth.hairline else {
                throw fail("\(label): the focus ring paints \(focused.lines["focusRing.border"] ?? -1)pt, not the \(LineWidth.hairline)pt hairline (P1.3/P1.4)")
            }
            guard focused.lines["card.border"] == 0 else {
                throw fail("\(label): a focused row grew a permanent perimeter of \(focused.lines["card.border"] ?? -1)pt — the ring is a separate temporary view, never the row's own edge")
            }
            // A ring may not outlive the selection it marks: move the selection
            // off the focused row and the ring goes with it.
            guard probe.inbox.selectRowsForQA(ids: [first]) else {
                throw fail("\(label): the selection must move off the focused row")
            }
            let unfocused = try ladderReading(probe.inbox, agent: second, theme: theme, label: label)
            guard !unfocused.isFocusRingVisible, probe.inbox.keyboardFocusAgentIdForQA == nil else {
                throw fail("\(label): the focus ring survived the selection moving off its row (P1.4)")
            }
            asserted += 1

            // 9 · Nothing permanent remains. Hover a row, then take the window's
            // key state away: both transient treatments go.
            _ = probe.inbox.hoverRowForQA(id: first)
            probe.inbox.resignKeyForQA()
            try expectNothingLit(probe.inbox, why: "the window stopped being key", label: label)
            asserted += 1

            // 10 · SCROLL, and ROW REUSE. Both are the stuck-hover bug: the row
            // under the pointer changes without the pointer moving. Hover is
            // re-derived from where the pointer actually is — which, in a
            // headless probe, is nowhere near the list — so nothing stays lit.
            _ = probe.inbox.hoverRowForQA(id: first)
            probe.inbox.scrollForQA(byPoints: AgentInboxView.rowHeight * 3)
            try expectNothingLit(probe.inbox, why: "the list scrolled under the pointer", label: label)
            _ = probe.inbox.hoverRowForQA(id: first)
            // A full re-render rebuilds every cell — the reuse path.
            probe.inbox.reload(rows: rows)
            try expectNothingLit(probe.inbox, why: "every row cell was rebuilt", label: label)
            asserted += 1
        }
        return asserted
    }

    /// P0.2's additive sidebar leg. It deliberately observes today's paint rather
    /// than blessing the later surface, truncation, or row-height decisions: those
    /// packets consume these live accessors and tighten the assertion in their own
    /// file fences.
    static func runSidebarUXChecks() throws {
        _ = NSApplication.shared
        let originalAppAppearance = NSApp?.appearance
        defer { NSApp?.appearance = originalAppAppearance }

        let zeroWidth = CGFloat(0)
        let zeroHeight = CGFloat(620)
        let expectedZeroSizeMessage = "sidebar-ux-check: probe host must have nonzero size (width=\(zeroWidth), height=\(zeroHeight))"
        do {
            _ = try makeSidebarProbeHost(
                width: zeroWidth, height: zeroHeight, appearanceName: .darkAqua
            )
            throw fail("sidebar-ux-check: zero-sized probe host was accepted")
        } catch let error as GeometryError {
            guard error.message == expectedZeroSizeMessage else { throw error }
        }

        // P0.3: the probe consumes the DEFECT corpus — the rows that can fail
        // the truncation, dead-space, elapsed, fan-out and identity packets —
        // never the Component Lab's baseline fixtures, whose committed PNGs
        // must stay byte-identical while this corpus grows.
        let rows = LabFixtures.inboxDefectRows()
        guard !rows.isEmpty else { throw fail("sidebar-ux-check: corpus is empty") }
        guard Set(rows.map(\.id)).count == rows.count else {
            throw fail("sidebar-ux-check: corpus agent ids are not unique")
        }
        // P4.8 pages the settled tail at `settledPageSize` rows, hiding the rest
        // behind a footer that is not an agent cell — which would make the
        // cells == rows assertion below fail at the symptom instead of the
        // cause. The corpus keeps its settled tail within the first page; a
        // packet that needs a longer tail must expand paging here first.
        let settledRows = rows.filter { InboxSort.section(for: $0.lifecycle, now: LabFixtures.inboxNow) == .settled }.count
        guard settledRows <= InboxSort.settledPageSize else {
            throw fail("sidebar-ux-check: corpus has \(settledRows) settled rows, past the \(InboxSort.settledPageSize)-row first page — expand paging in the probe before asserting cells == rows")
        }
        // P0.3: the host's height is DERIVED from the corpus, not fixed at 620pt.
        // Materialization is bounded by the viewport, so a 40-child fan-out in a
        // 620pt host would leave most rows unbuilt and cells == rows could never
        // hold. Pitch is the tallest row (a card) plus the inter-cell gap; +2
        // rows cover the shelf heading and a paging footer, and the tail slack
        // covers the scope control and the card/slim difference in its favour.
        let rowPitch = AgentInboxView.rowHeight + Space.s
        let probeHeight = CGFloat(
            (Double(rows.count + 2) * rowPitch + AgentInboxView.scopeControlHeight + 160).rounded(.up)
        )
        let widths: [CGFloat] = [
            CGFloat(WorkspaceSidebarConfig.minWidth),
            CGFloat(WorkspaceSidebarConfig.defaultWidth),
            320,
        ]
        var totalCells = 0
        var totalLabels = 0
        var totalTruncated = 0
        var observedTiers = Set<RowFitTier>()
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp?.appearance = NSAppearance(named: appearanceName)
            for width in widths {
                let probe = try makeSidebarProbeHost(
                    width: width, height: probeHeight, appearanceName: appearanceName
                )
                // The corpus carries parked rows, whose relative times are read
                // from the view's injected clock. The Lab's canned `inboxNow` is
                // what keeps the snoozed fixture ON the shelf (wake in its
                // future) and every rendered time deterministic between runs.
                probe.inbox.clock = { LabFixtures.inboxNow }
                // The shelf hides its rows behind a heading by default, and a
                // hidden row materializes no cell. Open it before rows are
                // applied so every corpus row is on screen and countable; the
                // heading itself is not an `AgentInboxRowCell` and stays out of
                // the count.
                probe.inbox.toggleShelf()
                let counts = try checkSidebarProbe(
                    probe, rows: rows, width: width, appearanceName: appearanceName
                )
                totalCells += counts.cells
                totalLabels += counts.labels
                totalTruncated += counts.truncated
                observedTiers.formUnion(counts.tiers)
            }
        }
        // P1.2/P1.4: the four-state ladder and the focus ring, driven through the
        // view's own hover / selection / route-active / keyboard inputs.
        let ladderAssertions = try checkSidebarInteractionLadder(rows: rows, probeHeight: probeHeight)
        // P2.2: the measured-fit tier ladder as arithmetic, plus the requirement
        // that every named tier is actually REACHED by a real row at a shipping
        // width. A tier nothing resolves to is a sacrifice nobody makes, and it
        // would let the ladder be satisfied by declaring three cases and using
        // one.
        let tierAssertions = try checkSidebarFitTierLadder()
        // Both ENDS of the ladder are reached by real rows at shipping widths. The
        // middle rung is reached too, at a width derived from a row's own
        // measurements inside `checkSidebarFitTierLadder` — see the note there for
        // why the corpus cannot express it at 220/280/320 and why this packet may
        // not add a fixture that would.
        guard observedTiers.contains(.full), observedTiers.contains(.captionHidden) else {
            throw fail("sidebar-ux-check: the corpus reached only \(observedTiers.map(\.rawValue).sorted().joined(separator: ", ")) across the gated widths — a tier no live row resolves to is not a tier (P2.2)")
        }
        print(String(
            format: "UIProbeGeometry: sidebar UX seam materialized %d live row cells (%d defect-corpus rows per leg) and measured %d labels across 220/280/320pt in Aqua and Dark Aqua; %d labels currently elide by drawable-width measurement; every row paints a zero perimeter, no shadow and no fill at rest, and no sidebar line exceeds %.1fpt with no nested boundary anywhere in the subtree; every card row draws its name on a band of its own between the meta band and the detail band, gives a childless row's name the whole text column, and carries the recorded sacrifice ladder (project < branch < meta < name < state == elapsed == required) as live compression resistances; %d interaction-ladder assertions held per appearance (resting < selected < hover < route-active by measured emphasis, hover outranking selection, a hairline focus ring distinct from selection, and nothing left lit after an exit, a deactivation, a scroll or a full rebuild); %d measured-fit tier assertions held (three tiers by measured need with no width literal, monotone, each sacrifice real, the name and the state never sacrificed, and every dropped column relocated to the accessibility label); zero-size host rejected with a named error",
            totalCells, rows.count, totalLabels, totalTruncated, LineWidth.hairline,
            ladderAssertions, tierAssertions
        ))
    }

    // MARK: - P0.4 — the inbox truncation gate at the widths that ship
    //
    // Ticket: docs/38-tickets/94-sidebar-native-ux/P0.4-inbox-geometry-gate.md
    //
    // The probe above OBSERVES truncation and reports a count; this gate makes
    // truncation a DECISION. Every label in the defect corpus is measured by
    // drawable width against the need for its exact string and font (the +4pt
    // cell inset included, via the same QA geometry the probe uses), at the
    // sidebar's shipping minimum, its default, and one wide step, in both
    // appearances. What may truncate is written down, per element, in
    // `expectedSidebarTruncations` below — the same pattern as the colour
    // hygiene allowlist: a NEW truncation is red naming the element and the
    // width it lost, and a tracked truncation that STOPS truncating is equally
    // red, so the P2.x fix that heals it must shrink the table in the same
    // change. Existing baselines already contain a blessed truncated title;
    // baselines are not the specification — this table is.
    //
    // P2.1 SPLIT THE TABLE IN TWO (`namesLongerThanTheRow` ∪ `sacrificedByOrder`,
    // below, and see the block above them for why). One flat set could not tell
    // "this name is wider than any line" apart from "this name yielded first
    // again", which is the difference the whole program turns on. Both red rules
    // in this file are unchanged and still measured over the union.
    //
    // ENTRY WITNESS (2026-08-04): with the table empty, `--ui-geometry-check`
    // exited 1 naming today's defects at the minimum width first, e.g.
    // `row0.title@min lost 118.4pt (needed 194.4, drawable 76.0)` — the
    // provider/model-id-as-a-name fixture, truncated exactly as the committed
    // chrome.agentInbox baselines bless it. The full red listing became the
    // table below; the table is the defect inventory P2.1/P2.2 burn down.
    //
    // P04-WIDTH-SCAN-BEGIN — the self-scan below rejects the sidebar's
    // minimum/default widths appearing as digit literals anywhere in this
    // region, so the gate can never drift from `WorkspaceSidebarConfig`.
    // Widths are symbolic here: min, default, wide.

    /// The three gated widths. Names, not numbers, so a table entry reads
    /// `row3.branch@min` and survives a config retune red-handed: retuning
    /// `WorkspaceSidebarConfig` re-measures every entry rather than silently
    /// un-gating a width.
    private static var sidebarGateWidths: [(name: String, width: CGFloat)] {
        [
            ("min", CGFloat(WorkspaceSidebarConfig.minWidth)),
            ("default", CGFloat(WorkspaceSidebarConfig.defaultWidth)),
            ("wide", 320),
        ]
    }

    // THE TABLE IS SPLIT IN TWO, and the split is P2.1's own requirement rather
    // than tidiness. With one flat set every surviving entry read as the
    // yields-first defect still being present, so the packet that fixed the
    // defect could not show its work: a `title` left in the table after P2.1
    // looks identical to a `title` that P2.1 failed to heal. The two sets below
    // say different things about the same shape of key.
    //
    //  · `namesLongerThanTheRow` — a DECISION. The row gave the name a whole
    //    line, the name is still wider than the line, and eliding its tail is
    //    the right answer: `AgentInboxCellView.nameCompressionResistance` means
    //    every other text on the row has already yielded before this happens.
    //    An entry here is not a defect; it is the recorded end of the ladder.
    //  · `sacrificedByOrder` — the RECORDED SACRIFICE, from the order P2.1
    //    wrote down (caption/project chip → branch → metrics → role/rollup →
    //    NAME). An entry here is a label that gave way ON PURPOSE so the name
    //    did not have to.
    //
    // `expectedSidebarTruncations` is their UNION and nothing else, so both red
    // rules above are unchanged: a key in neither set is a NEW truncation, and a
    // key in either set that stops truncating is a HEALED one that must be
    // deleted in the same change. Which set a key lives in is a claim about WHY
    // it is allowed, and the two claims are audited by different assertions —
    // the gate's own in-loop rule holds the name's set to "the row was already at
    // its tightest tier", and `expectRowBandsAndSacrificeOrder` holds the sacrifice
    // set to "the tier that dropped it really dropped it".

    /// Names wider than the whole line the row gives them, at the width named.
    /// Every entry is the LAST rung of the sacrifice ladder: the row band-split
    /// in P2.1 hands the name its own full-width line, and these names outrun
    /// even that. Every CARD `title@wide` and every CARD `title@default` is gone —
    /// P2.1 healed all 6 and all 48 of them by giving the name a line nothing
    /// else can take width from, and what is left is `@min` only.
    ///
    /// TWO ENTRIES HERE ARE NOT P2.1's: `row50` and `row51` are the corpus's only
    /// SLIM rows, and a slim row is one line holding four things — it has no bands
    /// to split and no tier to step down. `row51`'s three widths come from a time
    /// label the gate renders against an unpinned clock (`--sidebar-ux-check` pins
    /// it, this gate does not), which is P2.5's finding and P2.5's to heal. They
    /// are listed here rather than in `sacrificedByOrder` because they are names,
    /// not sacrifices; the gate's name rule and `expectRowBandsAndSacrificeOrder`
    /// both scope themselves to CARD rows for exactly that reason.
    private static let namesLongerThanTheRow: Set<String> = [
        "row0.title@min", "row10.title@min", "row11.title@min", "row12.title@min",
        "row13.title@min", "row14.title@min", "row15.title@min", "row16.title@min",
        "row17.title@min", "row18.title@min", "row19.title@min", "row20.title@min",
        "row21.title@min", "row22.title@min", "row23.title@min", "row24.title@min",
        "row25.title@min", "row26.title@min", "row27.title@min", "row28.title@min",
        "row29.title@min", "row3.title@min", "row30.title@min", "row31.title@min",
        "row32.title@min", "row33.title@min", "row34.title@min", "row35.title@min",
        "row36.title@min", "row37.title@min", "row38.title@min", "row39.title@min",
        "row4.title@min", "row40.title@min", "row41.title@min", "row42.title@min",
        "row43.title@min", "row44.title@min", "row46.title@min", "row47.title@min",
        "row5.title@min", "row50.title@min", "row51.title@default", "row51.title@min",
        "row51.title@wide", "row6.title@min", "row7.title@min", "row8.title@min",
        "row9.title@min",
    ]

    /// What gave way so the name did not have to, keyed the same way. Every
    /// entry traces to one rung of the order P2.1 recorded:
    ///
    ///  · `branch@*` — band 3 holds `meta` and `branch` on ONE line (the card
    ///    is exactly three lines of type, and P2.1 may not move a point of
    ///    height), and the branch is the lower-priority half of that pair by
    ///    the recorded order. It is also the label that survives elision best:
    ///    `.byTruncatingMiddle` keeps both ends of an `agent/<role>-<slug>`,
    ///    which is how a branch is recognised.
    ///  · `meta@min` — the five rows whose role/rollup line is long enough that
    ///    squeezing the branch to its yielding floor was not enough. Next rung
    ///    up, and the rung the name never reaches.
    ///
    /// NO `project@*` ENTRY SURVIVES, and its absence is P2.2's result rather than
    /// an omission: the caption is the FIRST rung, so the tightest tier stops
    /// drawing it, and a hidden label is not measured. All 4 are gone — `row2`'s
    /// at min the moment the project stopped sharing the name's line (P2.1), and
    /// `row48`'s three when `RowFitTier.captionHidden` took the over-long project
    /// off the row entirely (P2.2). The fact itself is not lost: it is folded into
    /// the cell's accessibility label, which `checkSidebarFitTierLadder` asserts.
    private static let sacrificedByOrder: Set<String> = [
        "row0.branch@default", "row0.branch@min", "row10.branch@default", "row10.branch@min",
        "row11.branch@default", "row11.branch@min", "row12.branch@default", "row12.branch@min",
        "row13.branch@default", "row13.branch@min", "row14.branch@default", "row14.branch@min",
        "row15.branch@default", "row15.branch@min", "row16.branch@default", "row16.branch@min",
        "row17.branch@default", "row17.branch@min", "row18.branch@default", "row18.branch@min",
        "row19.branch@default", "row19.branch@min", "row2.branch@min", "row20.branch@default",
        "row20.branch@min", "row21.branch@default", "row21.branch@min", "row22.branch@default",
        "row22.branch@min", "row23.branch@default", "row23.branch@min", "row24.branch@default",
        "row24.branch@min", "row25.branch@default", "row25.branch@min", "row26.branch@default",
        "row26.branch@min", "row27.branch@default", "row27.branch@min", "row28.branch@default",
        "row28.branch@min", "row29.branch@default", "row29.branch@min", "row3.branch@min",
        "row30.branch@default", "row30.branch@min", "row31.branch@default", "row31.branch@min",
        "row32.branch@default", "row32.branch@min", "row33.branch@default", "row33.branch@min",
        "row34.branch@default", "row34.branch@min", "row35.branch@default", "row35.branch@min",
        "row36.branch@default", "row36.branch@min", "row37.branch@default", "row37.branch@min",
        "row38.branch@default", "row38.branch@min", "row39.branch@default", "row39.branch@min",
        "row4.branch@default", "row4.branch@min", "row4.meta@min", "row40.branch@default",
        "row40.branch@min", "row41.branch@default", "row41.branch@min", "row42.branch@default",
        "row42.branch@min", "row43.branch@default", "row43.branch@min", "row44.branch@default",
        "row44.branch@min", "row45.branch@default", "row45.branch@min", "row45.meta@min",
        "row46.branch@default", "row46.branch@min", "row46.meta@min", "row47.branch@default",
        "row47.branch@min", "row47.branch@wide", "row47.meta@min", "row48.branch@min",
        "row49.branch@default", "row49.branch@min", "row49.meta@min", "row5.branch@min",
        "row50.branch@min", "row51.branch@default", "row51.branch@min", "row51.branch@wide",
        "row52.branch@min", "row6.branch@default", "row6.branch@min", "row7.branch@default",
        "row7.branch@min", "row8.branch@default", "row8.branch@min", "row9.branch@default",
        "row9.branch@min",
    ]

    /// What may truncate today: the two recorded sets and nothing else.
    private static var expectedSidebarTruncations: Set<String> {
        namesLongerThanTheRow.union(sacrificedByOrder)
    }

    static func checkSidebarTruncationGate() throws -> (measured: Int, truncated: Int) {
        _ = NSApplication.shared
        let originalAppAppearance = NSApp?.appearance
        defer { NSApp?.appearance = originalAppAppearance }

        try checkSidebarGateSourceHygiene()

        let rows = LabFixtures.inboxDefectRows()
        guard !rows.isEmpty else { throw fail("ui-geometry-check: sidebar gate corpus is empty") }
        var corpusIndexByID: [UUID: Int] = [:]
        for (index, row) in rows.enumerated() { corpusIndexByID[row.id] = index }

        let rowPitch = AgentInboxView.rowHeight + Space.s
        let probeHeight = CGFloat(
            (Double(rows.count + 2) * rowPitch + AgentInboxView.scopeControlHeight + 160).rounded(.up)
        )

        var measured = 0
        var observedByAppearance: [NSAppearance.Name: Set<String>] = [:]
        var lostWidthByKey: [String: String] = [:]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp?.appearance = NSAppearance(named: appearanceName)
            var observed: Set<String> = []
            for gate in sidebarGateWidths {
                let probe = try makeSidebarProbeHost(
                    width: gate.width, height: probeHeight, appearanceName: appearanceName
                )
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.reload(rows: rows)
                probe.inbox.layoutForQA()
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.layoutForQA()
                let geometries = probe.inbox.qaRowGeometriesForQA
                guard geometries.count == rows.count else {
                    throw fail("ui-geometry-check: sidebar gate materialized \(geometries.count) rows of \(rows.count) at \(gate.name)")
                }
                for geometry in geometries {
                    guard let id = geometry.agentID, let index = corpusIndexByID[id] else {
                        throw fail("ui-geometry-check: sidebar gate saw a row cell with no corpus identity at \(gate.name)")
                    }
                    for label in geometry.labels
                    where !label.isHidden && !label.text.isEmpty && label.frame.width > 0 {
                        measured += 1
                        if label.drawableWidth + 0.5 < label.neededWidth {
                            let key = "row\(index).\(label.element)@\(gate.name)"
                            observed.insert(key)
                            lostWidthByKey[key] = String(
                                format: "lost %.1fpt (needed %.1f, drawable %.1f)",
                                label.neededWidth - label.drawableWidth,
                                label.neededWidth, label.drawableWidth
                            )
                            // P2.1's SACRIFICE ORDER, asserted where the elision is
                            // actually observed rather than described in a comment:
                            // a NAME may only be found elided once the row has
                            // spent everything the order puts below it. On a card
                            // that means the tightest tier — the caption dropped
                            // and the metrics dropped — and the key must live in
                            // `namesLongerThanTheRow`, never in `sacrificedByOrder`.
                            if label.element == "title", geometry.variant == .card {
                                guard geometry.fitTier == .captionHidden else {
                                    throw fail("ui-geometry-check: \(key) elides the agent's NAME while the row is still on \(geometry.fitTier?.rawValue ?? "no") tier — the name yields last, so every lower rung of the recorded order must already have been spent (P2.1)")
                                }
                                guard !sacrificedByOrder.contains(key) else {
                                    throw fail("ui-geometry-check: \(key) is recorded as a SACRIFICE — a name is never sacrificed; an elided name belongs in namesLongerThanTheRow (P2.1)")
                                }
                            }
                        }
                    }
                }
            }
            observedByAppearance[appearanceName] = observed
        }

        // Truncation is string+font+width arithmetic: if the two appearances
        // disagree, a theme changed a font or an inset, which is its own bug.
        let aqua = observedByAppearance[.aqua] ?? []
        let dark = observedByAppearance[.darkAqua] ?? []
        guard aqua == dark else {
            let delta = aqua.symmetricDifference(dark).sorted()
            throw fail("ui-geometry-check: truncation differs between appearances — \(delta.joined(separator: ", "))")
        }

        let fresh = aqua.subtracting(expectedSidebarTruncations).sorted()
        guard fresh.isEmpty else {
            let named = fresh.map { "\($0) \(lostWidthByKey[$0] ?? "")" }
            throw fail("ui-geometry-check: NEW sidebar truncation not in the expected table — "
                + named.joined(separator: "; "))
        }
        let healed = expectedSidebarTruncations.subtracting(aqua).sorted()
        guard healed.isEmpty else {
            throw fail("ui-geometry-check: tracked sidebar truncation healed — remove from "
                + "expectedSidebarTruncations in the same change: \(healed.joined(separator: ", "))")
        }
        return (measured, aqua.count)
    }

    /// Widths come from `WorkspaceSidebarConfig`; a digit literal for the
    /// sidebar's minimum or default width inside the gate region is red, so a
    /// config retune can never leave this gate measuring yesterday's widths.
    private static func checkSidebarGateSourceHygiene() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        guard let begin = source.range(of: "P04-WIDTH-SCAN" + "-BEGIN"),
              let end = source.range(of: "P04-WIDTH-SCAN" + "-END") else {
            throw fail("ui-geometry-check: sidebar gate scan markers are missing")
        }
        let region = source[begin.upperBound..<end.lowerBound]
        let minLiteral = String(Int(WorkspaceSidebarConfig.minWidth))
        let defaultLiteral = String(Int(WorkspaceSidebarConfig.defaultWidth))
        for literal in [minLiteral, defaultLiteral] {
            var search = region.startIndex
            while let hit = region.range(of: literal, range: search..<region.endIndex) {
                let before = hit.lowerBound == region.startIndex ? " " : String(region[region.index(before: hit.lowerBound)])
                let after = hit.upperBound == region.endIndex ? " " : String(region[hit.upperBound])
                if !(before.last?.isNumber ?? false) && !(after.first?.isNumber ?? false) {
                    throw fail("ui-geometry-check: the sidebar gate hardcodes width \(literal) — read it from WorkspaceSidebarConfig instead")
                }
                search = hit.upperBound
            }
        }
    }
    // P04-WIDTH-SCAN-END

    /// P5.1 geometry gate for the v2 agent header shell. The shell stays behind
    /// its fixture flag until P5.5 acceptance, so this constructs the real view
    /// directly: wide/narrow layout, overflow hit target, truncation-not-clipping,
    /// tick-stable elapsed frame, and idle timer teardown.
    private static func checkAgentTileHeaderShell() throws {
        let longName = "an-agent-name-long-enough-to-need-truncation-at-narrow-width"
        for width in [CGFloat(900), CGFloat(320)] {
            let header = AgentTileHeaderView(
                frame: NSRect(x: 0, y: 0, width: width, height: AgentTileHeaderView.preferredHeight)
            )
            header.apply(AgentTileStatePresenter.present(
                name: longName,
                status: .working,
                branchContext: nil,
                startedAt: Date(timeIntervalSince1970: 100),
                now: Date(timeIntervalSince1970: 165)
            ))
            header.layoutSubtreeIfNeeded()
            guard let overflow = header.qaOverflowFrame, overflow.width == 28, overflow.height == 28,
                  header.bounds.insetBy(dx: -0.5, dy: -0.5).contains(overflow) else {
                throw fail("agent header: overflow action lost its 28pt hit target inside the shell at \(Int(width))pt")
            }
            guard let name = header.qaNameFrame, name.maxX <= overflow.minX,
                  name.minX >= 0, header.qaName == longName else {
                throw fail("agent header: name label escaped its lane at \(Int(width))pt — truncation must stay inside the shell")
            }
            let elapsedBefore = header.qaElapsedFrame
            header.qaTick(now: Date(timeIntervalSince1970: 226))
            guard header.qaElapsedFrame == elapsedBefore else {
                throw fail("agent header: a timer tick moved the elapsed label frame — ticks must not relayout")
            }
            guard header.qaTimerIsActive else {
                throw fail("agent header: working state did not keep its one-second timer")
            }
            header.apply(AgentTileStatePresenter.present(
                name: longName, status: .idle, branchContext: nil, startedAt: nil
            ))
            guard !header.qaTimerIsActive, header.qaElapsed == nil else {
                throw fail("agent header: settling idle did not tear the timer down and hide elapsed time")
            }
        }
    }

    /// P5.4 geometry gate for the actual migrated composition root. The committed
    /// Component Lab baseline intentionally remains on the rollback tile until P5.5,
    /// so this non-pixel gate covers the live v2 seam at all required widths/themes.
    private static func checkLiveV2AgentTileLayout() throws {
        for width in [CGFloat(320), 480, 640, 900] {
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let label = "managedAgent.v2@\(Int(width))pt.\(appearanceName.rawValue)"
                let probe = try UIProbe.render(
                    .init(id: label, size: NSSize(width: width, height: 560), appearance: appearanceName)
                ) {
                    LabCatalog.makeManagedAgentFixtureView(includeApproval: false)
                }
                guard let tile = probe.view as? ManagedAgentTileNSView,
                      tile.qaUsesV2Tile,
                      tile.qaUsesFullTurnComposer,
                      let transcript = tile.qaTranscriptCollectionFixture else {
                    throw fail("\(label): v2 constructor did not install semantic transcript/full-turn composer")
                }
                tile.layoutSubtreeIfNeeded()
                transcript.layoutSubtreeIfNeeded()
                guard !tile.qaHasLegacyComposeField, !tile.qaHasPermanentApprovalDock,
                      tile.qaV2RenderError == nil,
                      transcript.qaSemanticRowCount >= 4 else {
                    throw fail("\(label): v2 tile retained legacy UI or failed semantic rendering")
                }
                try fills(child: transcript, parent: tile, minRatio: 0.95, label: "\(label): semantic transcript")
                // P5.5 defect 6: a pixel gate cannot see this — the collection
                // view's default background is `windowBackgroundColor`, which only
                // shows its wallpaper tint on a live desktop, never in the blessed
                // offscreen renders.
                guard transcript.collectionView.backgroundColors == [.clear] else {
                    throw fail("\(label): the transcript collection view paints its own background (\(transcript.collectionView.backgroundColors)) over the tile's tileBody backdrop")
                }
                try expectNoZeroSizeViews(tile, label: label)
                try expectNoClipping(tile, label: label)
                try expectNoBrokenRequiredSizeConstraints(tile, label: label)
                // P5.5 defect 4: text truncation is invisible to the frame-only
                // checks above — a label ellipsizing inside its own well-contained
                // frame passes every one of them, which is how "Medi…" shipped at
                // 750 pt. Whenever the footer's measured fit says its current
                // titles fit, both pickers must hold their measured width and
                // render the selected title verbatim.
                let footer = tile.qaProviderFooterView
                footer.layoutSubtreeIfNeeded()
                if footer.qaFitsCurrentTitles {
                    for (name, button) in [("model", footer.modelButton), ("effort", footer.effortButton)] {
                        guard button.frame.width >= button.intrinsicContentSize.width - 0.5 else {
                            throw fail("\(label): \(name) picker squeezed below its measured width (frame \(button.frame.width), needs \(button.intrinsicContentSize.width)) — its title will ellipsize")
                        }
                        button.layoutSubtreeIfNeeded()
                        guard button.qaTitleDrawsWithoutTruncation else {
                            throw fail("\(label): \(name) picker's label is narrower than its title '\(button.qaRenderedTitle)' needs — the cell will draw an ellipsis")
                        }
                    }
                } else {
                    throw fail("\(label): the footer's own measured fit rejects its current titles — the fit tiers (full → abbreviated → captionless) must converge at every gate width")
                }
            }
        }
    }

    /// Deterministic behavior/geometry gate for the reusable custom choice
    /// surface. The disabled selection assertion is the required negative path:
    /// every input route converges on `choose(id:)`, whose guard it exercises.
    private static func checkChoicePopover() throws -> Int {
        let items = [
            ChoiceItem(id: "fast", title: "Fast", detail: "Lower latency"),
            ChoiceItem(id: "balanced", title: "Balanced", detail: "Recommended"),
            ChoiceItem(id: "legacy", title: "Legacy", detail: "Unavailable", enabled: false),
            ChoiceItem(id: "deep", title: "Deep", detail: "More reasoning"),
        ]
        let list = ChoiceListView(items: items, selectedID: "balanced")
        list.frame = NSRect(origin: .zero, size: list.intrinsicContentSize)
        list.layoutSubtreeIfNeeded()
        var selected: [String] = []
        list.onSelection = { selected.append($0.id) }

        guard list.selectedID == "balanced", list.focusedID == "balanced" else {
            throw fail("choice popover: initial selection/focus was not preserved")
        }
        // Owner corrections (P4.10): rows communicate selection through fill plus
        // checkmark and never paint a perimeter border; the panel keeps exactly one
        // ≤0.5 pt boundary; row density sits in the 34–36 pt band.
        guard let selectedRow = list.qaRowStates.first(where: { $0.id == "balanced" }),
              selectedRow.selected, selectedRow.focused, selectedRow.checkVisible,
              selectedRow.borderWidth == 0 else {
            throw fail("choice popover: selected row lost its checkmark or regained a perimeter border")
        }
        guard list.qaRowStates.allSatisfy({ $0.borderWidth == 0 }) else {
            throw fail("choice popover: a row painted a permanent perimeter border")
        }
        guard (34...36).contains(ChoiceListView.rowHeight) else {
            throw fail("choice popover: row height \(ChoiceListView.rowHeight) left the approved 34–36pt density band")
        }
        guard let panelBorder = list.layer?.borderWidth, panelBorder <= 0.5, panelBorder > 0 else {
            throw fail("choice popover: panel boundary is missing or heavier than 0.5pt")
        }
        guard let typeaheadEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "d",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 2
        ) else {
            throw fail("choice popover: could not synthesize typeahead event")
        }
        list.keyDown(with: typeaheadEvent)
        guard list.focusedID == "deep" else {
            throw fail("choice popover: typeahead did not focus the matching enabled row")
        }
        list.perform(.previous)
        guard list.focusedID == "balanced" else {
            throw fail("choice popover: keyboard traversal did not recover after typeahead")
        }

        // Required negative witness: a disabled row cannot change selection or
        // invoke the action. `CONTINUUM_P4_7_NEGATIVE_WITNESS=1` narrowly bypasses
        // the production guard so this exact assertion must go red.
        list.choose(id: "legacy")
        guard selected.isEmpty, list.selectedID == "balanced" else {
            throw fail("choice popover: disabled row fired selection")
        }

        list.perform(.next)
        guard list.focusedID == "deep" else {
            throw fail("choice popover: Down did not skip disabled row")
        }
        list.perform(.accept)
        guard selected == ["deep"], list.selectedID == "deep" else {
            throw fail("choice popover: Return did not accept focused enabled row")
        }
        list.perform(.first)
        guard list.focusedID == "fast" else { throw fail("choice popover: Home did not focus first enabled row") }
        list.perform(.last)
        guard list.focusedID == "deep" else { throw fail("choice popover: End did not focus last enabled row") }
        list.perform(.next)
        guard list.focusedID == "fast" else { throw fail("choice popover: keyboard traversal did not wrap") }
        var dismissed = false
        list.onDismiss = { dismissed = true }
        list.perform(.cancel)
        guard dismissed else { throw fail("choice popover: Escape did not dismiss") }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            list.appearance = NSAppearance(named: appearance)
            list.applyTokens()
            guard list.layer?.backgroundColor != nil,
                  list.qaRowStates.allSatisfy({ $0.enabled || !$0.focused }) else {
                throw fail("choice popover: invalid \(appearance.rawValue) token or disabled focus state")
            }
        }

        guard let screen = NSScreen.main else { throw fail("choice popover: no screen available") }
        let visible = screen.visibleFrame
        let windowSize = NSSize(width: 320, height: 240)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: .borderless, backing: .buffered, defer: false, screen: screen
        )
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 32))
        window.contentView?.addSubview(anchor)
        let controller = ChoicePopoverController()

        func presentAndCheck(windowY: CGFloat, expectedBelow: Bool) throws {
            window.setFrameOrigin(NSPoint(x: visible.midX - windowSize.width / 2, y: windowY))
            window.orderFront(nil)
            let windowAnchor = anchor.convert(anchor.bounds, to: nil)
            let screenAnchor = window.convertToScreen(windowAnchor)
            controller.present(
                items: items, selectedID: "balanced", anchor: anchor.bounds, relativeTo: anchor
            ) { _ in }
            guard let panel = controller.panel, panel.isVisible, controller.listView != nil else {
                throw fail("choice popover: present did not attach a visible panel")
            }
            let frame = panel.frame
            let placedBelow = frame.maxY <= screenAnchor.minY
            let placedAbove = frame.minY >= screenAnchor.maxY
            guard visible.contains(frame),
                  expectedBelow ? placedBelow : placedAbove else {
                throw fail("choice popover: \(expectedBelow ? "below" : "above") placement escaped screen or used the wrong anchor edge")
            }
            controller.dismiss()
            guard controller.panel == nil,
                  window.childWindows?.isEmpty != false,
                  anchor.postsFrameChangedNotifications else {
                throw fail("choice popover: dismiss left an attached panel or changed the anchor's notification policy")
            }
        }

        anchor.postsFrameChangedNotifications = true
        try presentAndCheck(windowY: visible.maxY - windowSize.height, expectedBelow: true)
        try presentAndCheck(windowY: visible.minY, expectedBelow: false)

        controller.present(
            items: items, selectedID: "balanced", anchor: anchor.bounds, relativeTo: anchor
        ) { _ in }
        guard let resigningPanel = controller.panel else {
            throw fail("choice popover: resign fixture could not present")
        }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: resigningPanel)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        guard controller.panel == nil,
              window.childWindows?.isEmpty != false,
              anchor.postsFrameChangedNotifications else {
            throw fail("choice popover: panel resign did not dismiss and restore its anchor")
        }

        controller.present(
            items: items, selectedID: "balanced", anchor: anchor.bounds, relativeTo: anchor
        ) { _ in }
        guard controller.isPresented else {
            throw fail("choice popover: detach fixture could not present")
        }
        anchor.removeFromSuperview()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        guard controller.panel == nil,
              window.childWindows?.isEmpty != false,
              anchor.postsFrameChangedNotifications else {
            throw fail("choice popover: anchor detach did not dismiss and restore notification policy")
        }
        window.contentView?.addSubview(anchor)

        // Deinitialization is also a lifecycle boundary: a controller released
        // while presented must detach its child panel and restore a prior false
        // frame-notification policy rather than leaking either into the tile.
        anchor.postsFrameChangedNotifications = false
        weak var releasedController: ChoicePopoverController?
        do {
            let transientController = ChoicePopoverController()
            releasedController = transientController
            transientController.present(
                items: items, selectedID: "balanced", anchor: anchor.bounds, relativeTo: anchor
            ) { _ in }
            guard transientController.isPresented else {
                throw fail("choice popover: deinit fixture could not present")
            }
        }
        guard releasedController == nil,
              !anchor.postsFrameChangedNotifications,
              window.childWindows?.isEmpty != false else {
            throw fail("choice popover: deinit did not restore the anchor and detach its panel")
        }
        window.orderOut(nil)

        let button = ChoiceButton(title: "Model")
        button.items = items
        button.selectedID = "balanced"
        guard firstDescendant(NSPopUpButton.self, in: button) == nil,
              button.accessibilityRole() == .popUpButton,
              button.accessibilityValue() as? String == "Balanced" else {
            throw fail("choice button: stock popup chrome or incomplete accessibility value")
        }
        // Owner correction (P4.10): the idle trigger is a quiet fill with no
        // outline and no focus glow.
        guard button.layer?.borderWidth == 0, button.layer?.shadowOpacity == 0 else {
            throw fail("choice button: idle state regained an outline or glow")
        }
        return 12
    }

    /// Width-sensitive TextKit gate for the one-to-eight-line composer. Explicit
    /// newlines make the line thresholds exact; the prose witness separately
    /// proves that measurement follows visual wrapping rather than newline count.
    private static func checkGrowingComposerLayout() throws -> Int {
        let widths: [CGFloat] = [320, 480, 640, 900]
        let drafts: [(name: String, text: String, lines: Int)] = [
            ("empty", "", 1),
            ("one-line", "One visual line", 1),
            ("eight-line", (1...8).map { "Line \($0)" }.joined(separator: "\n"), 8),
            ("twenty-line", (1...20).map { "Line \($0)" }.joined(separator: "\n"), 20),
        ]
        var checked = 0
        var wrappedHeights: [CGFloat: CGFloat] = [:]

        for width in widths {
            let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
            let host = NSView(frame: composer.frame)
            host.addSubview(composer)

            for draft in drafts {
                let end = (draft.text as NSString).length
                composer.apply(AgentComposerDraft(
                    text: draft.text, selection: NSRange(location: end, length: 0), revision: UInt64(checked + 1)
                ))
                let targetHeight = composer.intrinsicContentSize.height
                composer.frame = NSRect(x: 0, y: 0, width: width, height: targetHeight)
                host.frame.size = composer.frame.size
                host.layoutSubtreeIfNeeded()
                composer.layoutSubtreeIfNeeded()

                guard let measurement = composer.qaHeightMeasurement else {
                    throw fail("composer@\(Int(width))pt.\(draft.name): no TextKit measurement")
                }
                let expectedVisibleLines = min(draft.lines, AgentComposerView.maximumVisibleLines)
                let expectedEditorHeight = measurement.lineHeight * CGFloat(expectedVisibleLines)
                guard abs(measurement.visibleEditorHeight - expectedEditorHeight) <= 1,
                      abs(composer.frame.height - (measurement.visibleEditorHeight + AgentComposerView.internalPadding * 2)) <= 1,
                      measurement.isVerticallyScrollable == (draft.lines > AgentComposerView.maximumVisibleLines),
                      composer.scrollView.hasVerticalScroller == measurement.isVerticallyScrollable else {
                    throw fail(String(
                        format: "composer@%.0fpt.%@: measured %.1fpt (line %.1fpt), frame %.1fpt, scrolling %@",
                        width, draft.name, measurement.visibleEditorHeight, measurement.lineHeight,
                        composer.frame.height, measurement.isVerticallyScrollable.description
                    ))
                }
                let clip = composer.scrollView.contentView
                let maxY = max(0, composer.textView.bounds.height - clip.bounds.height)
                if draft.lines > AgentComposerView.maximumVisibleLines {
                    guard maxY > 0, abs(clip.bounds.minY - maxY) <= 1 else {
                        throw fail("composer@\(Int(width))pt did not keep the insertion point visible above its cap")
                    }
                } else if maxY > 1 || abs(clip.bounds.minY) > 1 {
                    throw fail("composer@\(Int(width))pt.\(draft.name) enabled scrolling below its cap")
                }
                checked += 1
            }

            let wrappingText = Array(repeating: "width-sensitive TextKit wrapping", count: 10).joined(separator: " ")
            composer.apply(AgentComposerDraft(
                text: wrappingText,
                selection: NSRange(location: (wrappingText as NSString).length, length: 0),
                revision: 100
            ))
            composer.frame.size.height = composer.intrinsicContentSize.height
            host.frame.size = composer.frame.size
            host.layoutSubtreeIfNeeded()
            composer.layoutSubtreeIfNeeded()
            guard let wrappedHeight = composer.qaHeightMeasurement?.contentHeight else {
                throw fail("composer@\(Int(width))pt wrapping witness was not measured")
            }
            wrappedHeights[width] = wrappedHeight

            // Existing draft text and line metrics must be refreshed when macOS
            // readability options change. A typing-attributes-only update leaves
            // this deliberately wrong font installed and fails the assertion.
            composer.textView.font = .systemFont(ofSize: 30)
            NotificationCenter.default.post(
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil
            )
            composer.frame.size.height = composer.intrinsicContentSize.height
            host.frame.size = composer.frame.size
            host.layoutSubtreeIfNeeded()
            composer.layoutSubtreeIfNeeded()
            let tokenFont = NSFont.token(.body)
            var existingTextUsesTokenFont = true
            composer.textView.textStorage?.enumerateAttribute(
                .font,
                in: NSRange(location: 0, length: composer.textView.textStorage?.length ?? 0)
            ) { value, _, stop in
                guard let font = value as? NSFont,
                      abs(font.pointSize - tokenFont.pointSize) <= 0.01,
                      font.fontName == tokenFont.fontName else {
                    existingTextUsesTokenFont = false
                    stop.pointee = true
                    return
                }
            }
            guard existingTextUsesTokenFont,
                  abs((composer.textView.font?.pointSize ?? 0) - tokenFont.pointSize) <= 0.01,
                  let refreshed = composer.qaHeightMeasurement,
                  abs(refreshed.lineHeight - (composer.textView.layoutManager?.defaultLineHeight(for: tokenFont) ?? 0)) <= 0.5 else {
                throw fail("composer@\(Int(width))pt did not refresh existing text font and height after a readability change")
            }

            // Capture after both capped and uncapped states have initialized
            // AppKit's private scroller constraints; only subsequent growth is a
            // constraint-churn failure owned by the composer.
            let initialConstraintCount = composer.constraints.count
                + composer.scrollView.constraints.count
                + composer.textView.constraints.count
            for index in 0..<40 {
                let text = index.isMultiple(of: 2) ? "short" : drafts[3].text
                composer.apply(AgentComposerDraft(
                    text: text, selection: NSRange(location: (text as NSString).length, length: 0),
                    revision: UInt64(200 + index)
                ))
                composer.frame.size.height = composer.intrinsicContentSize.height
                host.frame.size = composer.frame.size
                host.layoutSubtreeIfNeeded()
                composer.layoutSubtreeIfNeeded()
            }
            let finalConstraintCount = composer.constraints.count
                + composer.scrollView.constraints.count
                + composer.textView.constraints.count
            guard finalConstraintCount == initialConstraintCount else {
                throw fail("composer@\(Int(width))pt accumulated \(finalConstraintCount - initialConstraintCount) constraints during repeated edits")
            }
        }

        guard let narrow = wrappedHeights[320], let wide = wrappedHeights[900], narrow > wide + 1 else {
            throw fail("composer TextKit measurement did not respond to visual wrapping across widths")
        }
        return checked
    }

    // Negative witness (P4.2, exercised 2026-07-31): temporarily changing the
    // height controller initializer from `AgentComposerView.maximumVisibleLines`
    // to `1` left this fixture's semantic expectation at eight and made the final
    // check exit 1 at `composer@320pt.eight-line` (16pt instead of 128pt). Exact
    // source bytes were restored; production behavior has no witness backdoor.

    /// Deterministic P3.10 gate over the real diffable collection seam. The
    /// viewport is deliberately tiny relative to the 10,000-row document, so a
    /// permanent-view implementation fails by a measured live-host count.
    private static func checkTranscriptCollectionList() throws -> Int {
        func id(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }
        func block(_ index: Int, revision: UInt64 = 1) -> AgentBlock {
            AgentBlock(
                id: id("collection-block-\(index)"), revision: revision,
                kind: AgentBlockKind(rawValue: "fixture-opaque")!,
                payload: .opaque(AgentOpaquePayload(debugLabel: "row-\(index)", value: .null))
            )
        }

        let blocks = (0..<10_000).map { block($0) }
        let entry = AgentEntry(
            id: id("collection-entry"), revision: 1, role: .assistant,
            provenance: .localNotice(reason: "geometry fixture"), blocks: blocks
        )
        let document = AgentDocument(version: 1, entries: [entry])
        let initialPatch = try AgentDocumentPatch(
            fromVersion: 0, toVersion: 1, inserted: blocks.map(\.id)
        )

        let list = AgentTranscriptListView()
        if ProcessInfo.processInfo.environment["CONTINUUM_P3_10_NEGATIVE_WITNESS"] == "1" {
            list.qaRetainHostForEverySemanticRow = true
        }
        list.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let host = NSView(frame: list.frame)
        host.addSubview(list)
        list.autoresizingMask = [.width, .height]
        try list.apply(document: document, patch: initialPatch)
        host.layoutSubtreeIfNeeded()
        list.collectionView.layoutSubtreeIfNeeded()

        guard list.qaSemanticRowCount == 10_000 else {
            throw fail("transcript collection holds \(list.qaSemanticRowCount) semantic rows, expected 10000")
        }
        let live = list.qaLiveHostCount
        guard live > 0, live < 100 else {
            throw fail("transcript collection created \(live) live hosts for 10000 rows in a 240pt viewport")
        }
        try fills(
            child: list.collectionView, parent: list.scrollView.contentView,
            minRatio: 0.99, label: "transcript collection width pin"
        )

        func expectPreserved(
            _ before: [AgentNodeID: ObjectIdentifier],
            label: String
        ) throws {
            guard !before.isEmpty else { throw fail("\(label): no materialized hosts to compare") }
            let after = list.qaRepresentedHostIdentities
            let replaced = before.compactMap { id, identity in
                after[id] == identity ? nil : id.rawValue
            }
            guard replaced.isEmpty else {
                throw fail("\(label): replaced stable-ID hosts \(replaced.sorted().joined(separator: ","))")
            }
        }

        // Prove the content-only update against every currently represented host,
        // not one hand-picked sibling. The revised host must also update in place.
        let initialIdentities = list.qaRepresentedHostIdentities
        guard initialIdentities.count >= 2 else {
            throw fail("transcript collection materialized only \(initialIdentities.count) stable-ID hosts")
        }
        let firstID = blocks[0].id
        guard initialIdentities[firstID] != nil else {
            throw fail("transcript collection did not materialize its first stable-ID host")
        }
        var revisedBlocks = blocks
        revisedBlocks[0] = block(0, revision: 2)
        var revisedEntry = AgentEntry(
            id: entry.id, revision: 2, role: entry.role,
            provenance: entry.provenance, blocks: revisedBlocks
        )
        try list.apply(
            document: AgentDocument(version: 2, entries: [revisedEntry]),
            patch: try AgentDocumentPatch(fromVersion: 1, toVersion: 2, updated: [firstID, entry.id])
        )
        list.collectionView.layoutSubtreeIfNeeded()
        try expectPreserved(initialIdentities, label: "one-block transcript update")

        // Exercise the collection item's actual reset/rebind path with a retained
        // offscreen item. The next update therefore proves identity for every
        // visible host and for a host that crossed the reuse boundary.
        let middleUpdateIndex = 5_000
        let middleID = blocks[middleUpdateIndex].id
        try list.qaExerciseReuseBoundary(from: firstID, to: middleID)
        let middleIdentities = list.qaRepresentedHostIdentities
        guard middleIdentities[middleID] != nil else {
            throw fail("transcript collection did not retain the offscreen reuse witness")
        }

        revisedBlocks[middleUpdateIndex] = block(middleUpdateIndex, revision: 2)
        revisedEntry = AgentEntry(
            id: entry.id, revision: 3, role: entry.role,
            provenance: entry.provenance, blocks: revisedBlocks
        )
        try list.apply(
            document: AgentDocument(version: 3, entries: [revisedEntry]),
            patch: try AgentDocumentPatch(fromVersion: 2, toVersion: 3, updated: [middleID, entry.id])
        )
        list.collectionView.layoutSubtreeIfNeeded()
        try expectPreserved(middleIdentities, label: "offscreen-boundary one-block update")

        // A structural append outside the viewport must retain the reused
        // offscreen host and add exactly one semantic row without eager views.
        let appended = block(10_000)
        revisedBlocks.append(appended)
        revisedEntry = AgentEntry(
            id: entry.id, revision: 4, role: entry.role,
            provenance: entry.provenance, blocks: revisedBlocks
        )
        let beforeStructure = list.qaRepresentedHostIdentities
        try list.apply(
            document: AgentDocument(version: 4, entries: [revisedEntry]),
            patch: try AgentDocumentPatch(fromVersion: 3, toVersion: 4, inserted: [appended.id])
        )
        list.collectionView.layoutSubtreeIfNeeded()
        guard list.qaSemanticRowCount == 10_001,
              list.qaRepresentedHostIdentities[middleID] == beforeStructure[middleID] else {
            throw fail("offscreen structural append lost semantic data or replaced the reused offscreen host")
        }

        guard list.qaLiveHostCount < 100 else {
            throw fail("incremental transcript updates retained \(list.qaLiveHostCount) live hosts")
        }
        return live
    }

    // Negative witness (P3.10, exercised 2026-07-30):
    // `CONTINUUM_P3_10_NEGATIVE_WITNESS=1 .build/debug/continuum-revived --ui-geometry-check`
    // retained one host per semantic row, directly recreating the forbidden
    // permanent-stack architecture; exit 1:
    // "FAIL: transcript collection created 10005 live hosts for 10000 rows in a
    // 240pt viewport". The injection was then disabled and the same check passed.

    /// Deterministic P3.11 gate over the actual scheduler/list/controllers.
    /// It keeps reducer patch validity separate from visual coalescing and then
    /// checks the reader-facing policies on real AppKit scroll coordinates.
    private static func checkIncrementalTranscriptBehavior() throws -> Int {
        func id(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }
        func paragraph(_ index: Int, revision: UInt64 = 1, text: String? = nil) -> AgentBlock {
            AgentBlock(
                id: id("stream-block-\(index)"), revision: revision, kind: .paragraph,
                payload: .paragraph([.text(text ?? "Transcript row \(index)")])
            )
        }
        func hostedList(width: CGFloat = 320, height: CGFloat = 240) -> (NSView, AgentTranscriptListView) {
            let list = AgentTranscriptListView()
            list.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let host = NSView(frame: list.frame)
            host.addSubview(list)
            list.autoresizingMask = [.width, .height]
            return (host, list)
        }

        // 5,000 valid sequential reducer results collapse to one final visual
        // snapshot. Exact row comparison invalidates only the changing block.
        var streamBlocks = (0..<40).map { paragraph($0) }
        let streamEntryID = id("stream-entry")
        var streamEntry = AgentEntry(
            id: streamEntryID, revision: 1, role: .assistant,
            provenance: .localNotice(reason: "stream fixture"), blocks: streamBlocks
        )
        let (streamHost, streamList) = hostedList()
        try streamList.apply(
            document: AgentDocument(version: 1, entries: [streamEntry]),
            patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: streamBlocks.map(\.id))
        )
        streamHost.layoutSubtreeIfNeeded()
        streamList.collectionView.layoutSubtreeIfNeeded()
        let prepareBefore = streamList.qaLayoutPreparePassCount
        for delta in 1...5_000 {
            let version = UInt64(delta + 1)
            streamBlocks[39] = paragraph(39, revision: version, text: "Streaming value \(delta)")
            streamEntry = AgentEntry(
                id: streamEntryID, revision: version, role: .assistant,
                provenance: streamEntry.provenance, blocks: streamBlocks
            )
            try streamList.enqueue(
                document: AgentDocument(version: version, entries: [streamEntry]),
                patch: try AgentDocumentPatch(
                    fromVersion: version - 1, toVersion: version,
                    updated: [streamEntryID, streamBlocks[39].id]
                ),
                final: delta == 5_000
            )
        }
        streamHost.layoutSubtreeIfNeeded()
        streamList.collectionView.layoutSubtreeIfNeeded()
        guard streamList.qaVisualApplyCount == 1,
              streamList.qaLastInvalidatedTopLevelCount == 1,
              streamList.qaLayoutPreparePassCount - prepareBefore <= 3,
              streamList.qaSemanticRowCount == 40,
              streamList.qaRenderingErrorDescription == nil else {
            throw fail(
                "5000 transcript deltas produced \(streamList.qaVisualApplyCount) visual applies, "
                    + "\(streamList.qaLastInvalidatedTopLevelCount) invalidated rows, and "
                    + "\(streamList.qaLayoutPreparePassCount - prepareBefore) layout prepares"
            )
        }

        // An impossible document/patch pair is rejected before it can replace
        // the scheduler's valid pending snapshot.
        do {
            let invalidPatch = try AgentDocumentPatch(fromVersion: 5_001, toVersion: 5_002)
            try streamList.enqueue(
                document: AgentDocument(version: 5_003, entries: [streamEntry]),
                patch: invalidPatch
            )
            throw fail("transcript scheduler accepted a mismatched document/patch pair")
        } catch let error as AgentTranscriptListView.UpdateError {
            guard case .documentPatchMismatch(document: 5_003, patch: 5_002) = error else {
                throw fail("transcript scheduler rejected mismatch with wrong error: \(error)")
            }
        }

        // Exercise insertion-above anchoring on the real list, including the
        // inter-row spacing offset where the earlier row-zero fallback failed.
        var anchorBlocks = (0..<80).map { paragraph($0) }
        let anchorEntryID = id("anchor-entry")
        var anchorEntry = AgentEntry(
            id: anchorEntryID, revision: 1, role: .assistant,
            provenance: .localNotice(reason: "anchor fixture"), blocks: anchorBlocks
        )
        let (anchorHost, anchorList) = hostedList()
        try anchorList.apply(
            document: AgentDocument(version: 1, entries: [anchorEntry]),
            patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: anchorBlocks.map(\.id))
        )
        anchorHost.layoutSubtreeIfNeeded()
        anchorList.collectionView.layoutSubtreeIfNeeded()
        let anchorIndex = 40
        let anchorID = anchorBlocks[anchorIndex].id
        guard let oldFrame = anchorList.collectionView.layoutAttributesForItem(
            at: IndexPath(item: anchorIndex, section: 0)
        )?.frame else { throw fail("anchor fixture has no middle-row layout attributes") }
        let oldOffset = CGFloat(-4) // viewport starts in spacing immediately above the row
        anchorList.scrollView.contentView.scroll(to: NSPoint(x: 0, y: oldFrame.minY + oldOffset))
        anchorList.scrollView.reflectScrolledClipView(anchorList.scrollView.contentView)

        let inserted = AgentBlock(
            id: id("stream-inserted-heading"), revision: 1, kind: .heading,
            payload: .heading(level: 2, content: [.text("Inserted heading")])
        )
        anchorBlocks.insert(inserted, at: 0)
        anchorEntry = AgentEntry(
            id: anchorEntryID, revision: 2, role: .assistant,
            provenance: anchorEntry.provenance, blocks: anchorBlocks
        )
        try anchorList.apply(
            document: AgentDocument(version: 2, entries: [anchorEntry]),
            patch: try AgentDocumentPatch(
                fromVersion: 1, toVersion: 2,
                inserted: [inserted.id], updated: [anchorEntryID]
            )
        )
        anchorHost.layoutSubtreeIfNeeded()
        anchorList.collectionView.layoutSubtreeIfNeeded()
        guard let newFrame = anchorList.collectionView.layoutAttributesForItem(
            at: IndexPath(item: anchorIndex + 1, section: 0)
        )?.frame else { throw fail("insert-above fixture lost anchored row") }
        let restoredOffset = anchorList.scrollView.contentView.bounds.minY - newFrame.minY
        guard abs(restoredOffset - oldOffset) <= 0.5, anchorList.qaShowsJumpToLatest else {
            throw fail("insert-above moved reader anchor: offset \(oldOffset) became \(restoredOffset)")
        }

        // Select text inside a real virtualized rich-text renderer, then insert
        // above it. AgentTranscriptListView.hasActiveTextSelection() must choose
        // the stationary path—this is not a controller-only stub.
        func firstTextView(in view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView, !textView.string.isEmpty { return textView }
            return view.subviews.lazy.compactMap(firstTextView).first
        }
        guard let selectedTextView = firstTextView(in: anchorList.collectionView),
              (selectedTextView.string as NSString).length > 0 else {
            throw fail("selection fixture materialized no transcript text view")
        }
        selectedTextView.setSelectedRange(NSRange(location: 0, length: 1))
        let stationaryY = anchorList.scrollView.contentView.bounds.minY
        let copyBlock = AgentBlock(
            id: id("stream-copy-edge-cases"), revision: 1, kind: .paragraph,
            payload: .paragraph([
                .text("Soft"), .softBreak, .code("a`b"), .hardBreak, .text("End"),
            ])
        )
        anchorBlocks.insert(copyBlock, at: 0)
        anchorEntry = AgentEntry(
            id: anchorEntryID, revision: 3, role: .assistant,
            provenance: anchorEntry.provenance, blocks: anchorBlocks
        )
        try anchorList.apply(
            document: AgentDocument(version: 3, entries: [anchorEntry]),
            patch: try AgentDocumentPatch(
                fromVersion: 2, toVersion: 3,
                inserted: [copyBlock.id], updated: [anchorEntryID]
            )
        )
        anchorHost.layoutSubtreeIfNeeded()
        anchorList.collectionView.layoutSubtreeIfNeeded()
        guard abs(anchorList.scrollView.contentView.bounds.minY - stationaryY) <= 0.5,
              anchorList.qaShowsJumpToLatest else {
            throw fail("actual transcript text selection was force-scrolled during insert-above update")
        }
        selectedTextView.setSelectedRange(NSRange(location: 0, length: 0))

        // Inspect the order returned by the real accessibilityChildren override;
        // do not pre-sort a QA projection before asserting it.
        let accessibilityChildren = anchorList.accessibilityChildren() ?? []
        let accessibilityIDs = accessibilityChildren.compactMap {
            ($0 as? AgentBlockHostView)?.representedID
        }
        let documentIndexes = Dictionary(uniqueKeysWithValues: anchorBlocks.enumerated().map { ($0.element.id, $0.offset) })
        let accessibilityIndexes = accessibilityIDs.compactMap { documentIndexes[$0] }
        let hasJumpAction = accessibilityChildren.contains { child in
            (child as? NSButton)?.accessibilityLabel() == "Jump to latest transcript content"
        }
        guard accessibilityIDs.count >= 2,
              accessibilityIndexes == accessibilityIndexes.sorted(),
              anchorList.accessibilityRole() == .group,
              anchorList.collectionView.accessibilityRole() == .list,
              hasJumpAction else {
            throw fail("transcript VoiceOver children did not follow document order or expose Jump to latest")
        }

        // Standard block selection reaches semantic plain/Markdown copy and
        // matches native inline behavior for soft breaks and embedded backticks.
        anchorList.collectionView.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        let pasteboard = NSPasteboard(name: .init("continuum.transcript-copy.\(UUID().uuidString)"))
        anchorList.copySelectedBlocks(pasteboard: pasteboard)
        guard pasteboard.string(forType: .string) == "Soft a`b\nEnd",
              pasteboard.string(forType: .init("net.daringfireball.markdown")) == "Soft\n`a\\`b`  \nEnd" else {
            throw fail("transcript copy diverged from native soft-break/code Markdown semantics")
        }

        anchorList.jumpToLatest()
        guard anchorList.scrollController.isNearBottom(in: anchorList.scrollView),
              !anchorList.qaShowsJumpToLatest else {
            throw fail("Jump to latest did not reach the transcript end and clear itself")
        }
        return streamList.qaVisualApplyCount
    }

    // Negative witness (P3.11): with CONTINUUM_P3_11_NEGATIVE_WITNESS=1,
    // AgentTranscriptUpdateScheduler flushes every scheduled delta. The normal
    // 5,000-delta geometry assertion must fail with 5,000 visual applies.

    /// Deterministic P3.3 gate over the real renderer and reusable host seam.
    private static func checkAssistantProseRenderer() throws -> Int {
        func id(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }
        func paragraph(_ value: String, _ text: String) -> AgentBlock {
            AgentBlock(id: id(value), revision: 1, kind: .paragraph, payload: .paragraph([.text(text)]))
        }

        let heading = AgentBlock(
            id: id("prose-heading"), revision: 1, kind: .heading,
            payload: .heading(level: 2, content: [.text("Implementation notes")])
        )
        let item = AgentBlock(
            id: id("prose-item"), revision: 1, kind: .listItem, payload: .listItem,
            children: [paragraph(
                "prose-item-text",
                "Keep semantic identity stable while this deliberately long list item wraps at the narrow reading width."
            )]
        )
        let list = AgentBlock(
            id: id("prose-list"), revision: 1, kind: .list,
            payload: .list(AgentListPayload(ordered: false)), children: [item]
        )
        let quote = AgentBlock(
            id: id("prose-quote"), revision: 1, kind: .quote, payload: .quote,
            children: [heading, paragraph(
                "prose-paragraph",
                "Assistant prose is the quiet reading path and must wrap cleanly without becoming a decorative card at 320 points."
            ), list]
        )

        for kind in AssistantProseRenderer.supportedKinds {
            guard try AgentBlockRendererRegistry.production.renderer(for: kind) is AssistantProseRenderer else {
                throw fail("production registry did not select AssistantProseRenderer for \(kind.rawValue)")
            }
        }
        let context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

        let host = AgentBlockHostView()
        let height = try host.measuredHeight(for: quote, width: 320, context: context)
        guard height > CGFloat(Metrics.lineHeight(for: .body)) * 3 else {
            throw fail("assistant prose narrow fixture did not wrap; measured only \(height)pt")
        }
        host.frame = NSRect(x: 0, y: 0, width: 320, height: height)
        try host.apply(block: quote, context: context)
        host.layoutSubtreeIfNeeded()
        guard let prose = host.rendererView as? AssistantProseView else {
            throw fail("assistant prose registry did not vend AssistantProseView")
        }
        guard prose.textFields.count == 3, prose.textFields.allSatisfy(\.isSelectable) else {
            throw fail("assistant prose did not expose three selectable semantic rows")
        }
        guard prose.isFlipped,
              zip(prose.textFields, prose.textFields.dropFirst()).allSatisfy({
                  $0.frame.minY < $1.frame.minY
              }) else {
            throw fail("assistant prose did not preserve semantic rows in visual top-to-bottom order")
        }
        let headingRole = NSAccessibility.Role(rawValue: "AXHeading")
        let listItemRole = NSAccessibility.Role(rawValue: "AXListItem")
        guard prose.textFields.contains(where: { $0.accessibilityRole() == headingRole }),
              prose.textFields.contains(where: { $0.accessibilityRole() == listItemRole }) else {
            throw fail("assistant prose lost heading or list-item accessibility semantics")
        }
        let requiredInset = CGFloat(Inset.card.left)
        guard AssistantProseView.horizontalReadingInset == requiredInset,
              prose.textFields.allSatisfy({
                  $0.frame.minX == requiredInset
                      && $0.frame.maxX <= prose.bounds.maxX - requiredInset + 0.5
                      && $0.frame.maxY <= prose.bounds.maxY + 0.5
              }) else {
            throw fail("assistant prose rows clipped or escaped the horizontal reading inset at 320pt")
        }
        try expectNoAmbiguousLayout([(host, "prose host"), (prose, "prose view")], label: "assistant prose@320pt")

        let listHost = AgentBlockHostView()
        let listHeight = try listHost.measuredHeight(for: list, width: 320, context: context)
        listHost.frame = NSRect(x: 0, y: 0, width: 320, height: listHeight)
        try listHost.apply(block: list, context: context)
        listHost.layoutSubtreeIfNeeded()
        guard let listView = listHost.rendererView as? AssistantProseView,
              listView.accessibilityRole() == .list else {
            throw fail("assistant prose list root did not expose the list accessibility role")
        }
        return prose.textFields.count + listView.textFields.count
    }

    // Negative witness (P3.3, exercised 2026-07-30): changed
    // `horizontalReadingInset` to 0, rebuilt, then ran
    // `.build/debug/continuum-revived --ui-geometry-check`; exit 1:
    // "FAIL: assistant prose rows clipped or escaped the horizontal reading inset
    // at 320pt". The mutation was then reverted and the same check passed.

    /// Deterministic P3.4 gate over the semantic user surface at the program's
    /// narrowest required transcript width.
    private static func checkUserPromptRenderer() throws -> Int {
        func id(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }
        func paragraph(_ value: String, _ text: String) -> AgentBlock {
            AgentBlock(id: id(value), revision: 1, kind: .paragraph, payload: .paragraph([.text(text)]))
        }

        let prompt = AgentBlock(
            id: id("user-prompt-root"), revision: 1, kind: .quote, payload: .quote,
            children: [
                paragraph("user-prompt-first", "Please review the semantic transcript implementation and keep the response within the existing architecture."),
                paragraph("user-prompt-second", "Also preserve this second Markdown paragraph so multiline prompts remain selectable and readable at narrow widths."),
            ]
        )
        guard try AgentBlockRendererRegistry.production.renderer(
            for: prompt.kind, entryRole: .user
        ) is UserPromptRenderer else {
            throw fail("production role-aware registry did not select UserPromptRenderer for user quote")
        }
        guard try AgentBlockRendererRegistry.production.renderer(
            for: prompt.kind, entryRole: .assistant
        ) is AssistantProseRenderer else {
            throw fail("production role-aware registry replaced assistant quote with the user surface")
        }
        let context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
        let host = AgentBlockHostView()
        let height = try host.measuredHeight(
            for: prompt, entryRole: .user, width: 320, context: context
        )
        let assistantHeight = try host.measuredHeight(
            for: prompt, entryRole: .assistant, width: 320, context: context
        )
        guard height > CGFloat(Metrics.lineHeight(for: .body)) * 4,
              height == assistantHeight + UserPromptView.verticalInset * 2,
              host.measurementCache.cachedMeasurementCount == 2 else {
            throw fail("user/assistant role-aware measurement did not wrap or isolate cache entries (user \(height), assistant \(assistantHeight), cache \(host.measurementCache.cachedMeasurementCount))")
        }

        host.frame = NSRect(x: 0, y: 0, width: 320, height: height)
        try host.apply(block: prompt, entryRole: .user, context: context)
        host.layoutSubtreeIfNeeded()
        guard let view = host.rendererView as? UserPromptView else {
            throw fail("production block host did not select UserPromptView for a user entry")
        }

        guard view.accessibilityRole() == .group, view.accessibilityLabel() == "You" else {
            throw fail("user prompt did not expose the nonvisual You role label")
        }
        guard view.proseView.textFields.count == 2,
              view.proseView.textFields.allSatisfy(\.isSelectable),
              view.proseView.textFields.allSatisfy({ !$0.stringValue.contains("You ·") && $0.stringValue != "You" }) else {
            throw fail("user prompt lost a semantic Markdown row, selection, or drew a permanent You metadata caption")
        }
        guard view.proseView.frame.minX == view.bounds.minX else {
            throw fail("user prompt became right-aligned instead of sharing the prose leading edge")
        }
        try expectUserPromptReadableMeasure(
            proseWidth: view.proseView.frame.width, surfaceWidth: view.bounds.width
        )
        let inset = AssistantProseView.horizontalReadingInset
        guard view.proseView.textFields.allSatisfy({
            $0.frame.minX == inset && $0.frame.maxX <= view.proseView.bounds.maxX - inset + 0.5
                && $0.frame.maxY <= view.proseView.bounds.maxY + 0.5
        }) else {
            throw fail("user prompt does not share assistant prose's readable width or clips multiline content")
        }
        guard abs(view.proseView.frame.minY - UserPromptView.verticalInset) <= 0.5,
              abs(view.bounds.maxY - view.proseView.frame.maxY - UserPromptView.verticalInset) <= 0.5 else {
            throw fail("user prompt did not apply its modest symmetric vertical inset")
        }
        try expectNoAmbiguousLayout(
            [(view, "user prompt"), (view.proseView, "user prompt prose")], label: "user prompt@320pt"
        )
        try expectNoClipping(view, label: "user prompt@320pt")

        let userViewIdentity = ObjectIdentifier(view)
        try host.apply(block: prompt, entryRole: .assistant, context: context)
        guard let assistantView = host.rendererView as? AssistantProseView,
              ObjectIdentifier(assistantView) != userViewIdentity,
              host.representedRole == .assistant,
              assistantView.accessibilityLabel() == nil else {
            throw fail("same block did not replace its user renderer when entry role changed to assistant")
        }

        return view.proseView.textFields.count
    }

    private static func expectUserPromptReadableMeasure(
        proseWidth: CGFloat,
        surfaceWidth: CGFloat
    ) throws {
        guard surfaceWidth > 0 else { throw fail("user prompt surface has zero width") }
        let ratio = proseWidth / surfaceWidth
        guard ratio >= 0.99 else {
            throw fail(String(
                format: "user prompt became a narrow bubble: prose spans %.3f of its %.0fpt surface",
                ratio, surfaceWidth
            ))
        }
    }

    /// Deterministic P3.6 gate over the real TextKit code surface. This is direct
    /// renderer coverage while the transcript collection integration remains a
    /// later ticket; it still uses the frozen renderer protocol and semantic AST.
    private static func checkCodeBlockRenderer() throws -> Int {
        let id = AgentNodeID(rawValue: "code-block-geometry")!
        let original = "let greeting = \"hello\"\n    print(greeting)\n"
        let streamed = original + "\n"
        guard try AgentBlockRendererRegistry.production.renderer(for: .fencedCode) is CodeBlockRenderer else {
            throw fail("production registry did not resolve CodeBlockRenderer for fenced code")
        }

        var copiedActions: [AgentNodeID] = []
        let context = AgentRenderContext(
            actions: AgentRenderActions { action in
                if case let .copy(blockID) = action { copiedActions.append(blockID) }
            }, tokens: .transcript, appearance: .dark
        )
        let open = AgentBlock(
            id: id, revision: 1, kind: .fencedCode,
            payload: .fencedCode(.init(language: "swift", code: original, isComplete: false))
        )
        let revised = AgentBlock(
            id: id, revision: 2, kind: .fencedCode,
            payload: .fencedCode(.init(language: "swift", code: streamed, isComplete: false))
        )
        let host = AgentBlockHostView()
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
        try host.apply(block: open, context: context)
        guard let view = host.rendererView as? CodeBlockView else {
            throw fail("production block host did not vend CodeBlockView for fenced code")
        }
        host.layoutSubtreeIfNeeded()
        let textIdentity = ObjectIdentifier(view.codeTextView)
        view.codeTextView.setSelectedRange(NSRange(location: 4, length: 8))
        try host.apply(block: revised, context: context)
        guard ObjectIdentifier(view.codeTextView) == textIdentity,
              view.codeTextView.string == streamed,
              view.codeTextView.selectedRange() == NSRange(location: 4, length: 8) else {
            throw fail("one-character fenced-code update recreated TextKit, changed bytes, or lost selection")
        }
        let expectedSpan = HighlightSpan(range: NSRange(location: 0, length: (streamed as NSString).length))
        guard view.codeTextView.appliedSpans == [expectedSpan] else {
            throw fail("plain code highlighter did not cover the exact UTF-16 code range")
        }

        struct HostileCodeHighlighter: CodeHighlighting {
            func spans(language: String?, code: String) -> [HighlightSpan] {
                let length = (code as NSString).length
                return [
                    HighlightSpan(range: NSRange(location: -1, length: 1)),
                    HighlightSpan(range: NSRange(location: 0, length: -1)),
                    HighlightSpan(range: NSRange(location: length, length: 1)),
                    HighlightSpan(range: NSRange(location: Int.max, length: 1)),
                ]
            }
        }
        let hostileTextView = CodeTextView(highlighter: HostileCodeHighlighter())
        hostileTextView.apply(code: original, language: "swift", context: context)
        guard hostileTextView.appliedSpans.isEmpty, hostileTextView.string == original else {
            throw fail("code highlighter accepted a negative, overflowing, or out-of-bounds span")
        }
        guard view.streamingLabel.isHidden == false,
              !view.codeTextView.string.contains("Streaming"),
              view.languageLabel.stringValue == "swift" else {
            throw fail("incomplete fenced code changed code bytes or lost its subtle state/language labels")
        }

        var appearanceFills: [NSColor] = []
        for (name, theme) in [(NSAppearance.Name.aqua, TokenTheme.light), (.darkAqua, .dark)] {
            view.appearance = NSAppearance(named: name)
            view.applyTokens()
            guard let fill = view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
                  let textColor = view.codeTextView.textColor,
                  fill.isEqual(context.tokens.codeSurface.color.nsColor(for: theme)),
                  textColor.isEqual(context.tokens.primaryText.color.nsColor(for: theme)) else {
                throw fail("code block did not repaint token fill/text for \(name.rawValue)")
            }
            appearanceFills.append(fill)
        }
        guard appearanceFills.count == 2, !appearanceFills[0].isEqual(appearanceFills[1]) else {
            throw fail("code block light/dark appearance flip retained a stale surface")
        }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("continuum.code-block-check.\(UUID().uuidString)"))
        view.copyEntireBlock(to: pasteboard)
        guard pasteboard.string(forType: .string) == streamed else {
            throw fail("copy affordance did not preserve indentation or trailing newline bytes")
        }
        let buttonTitles = view.subviews.compactMap({ ($0 as? NSButton)?.title })
        guard view.copyButton.isBordered == false,
              view.copyButton.accessibilityLabel() == "Copy code",
              buttonTitles.allSatisfy({ $0 != "Execute" }) else {
            throw fail("code block exposed Aqua/Execute chrome or lost the named copy action")
        }
        view.copyButton.performClick(nil)
        guard NSPasteboard.general.string(forType: .string) == streamed,
              copiedActions == [id] else {
            throw fail("visible copy affordance did not preserve exact code or report its semantic action")
        }

        let longLine = String(repeating: "0123456789", count: 100)
        let longCode = (0..<80).map { "\($0): \(longLine)" }.joined(separator: "\n") + "\n"
        let longBlock = AgentBlock(
            id: id, revision: 3, kind: .fencedCode,
            payload: .fencedCode(.init(language: nil, code: longCode, isComplete: true))
        )
        let height = try host.measuredHeight(for: longBlock, width: 320, context: context)
        guard CodeBlockView.maximumExpandedHeight == 320, height == 320 else {
            throw fail("long fenced code was not capped at 320.0pt (measured \(height))")
        }
        host.frame = NSRect(x: 0, y: 0, width: 320, height: height)
        try host.apply(block: longBlock, context: context)
        host.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        guard view.scrollView.hasHorizontalScroller, view.scrollView.hasVerticalScroller,
              view.codeTextView.frame.width > view.scrollView.contentSize.width,
              view.codeTextView.frame.height > view.scrollView.contentSize.height,
              view.streamingLabel.isHidden,
              view.codeTextView.string == longCode else {
            throw fail("long fenced code did not retain exact bytes inside dual-axis internal scrolling")
        }
        guard view.accessibilityRole() == .group,
              view.accessibilityLabel() == "Code block",
              view.accessibilityChildren()?.contains(where: { ($0 as? NSButton)?.accessibilityLabel() == "Copy code" }) == true else {
            throw fail("code block accessibility lost its semantic group or copy action")
        }
        try expectNoAmbiguousLayout(
            [(view, "code block"), (view.scrollView, "code scroll view")], label: "code block@320pt"
        )
        guard view.languageLabel.frame.minX >= view.bounds.minX,
              view.copyButton.frame.maxX <= view.bounds.maxX,
              view.scrollView.frame.maxY <= view.bounds.maxY else {
            throw fail("code block header or scroll viewport clipped at 320pt")
        }
        guard copiedActions == [id] else {
            throw fail("code block reported an unexpected agent action during layout")
        }
        return longCode.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        }
    }

    // Negative witness (P3.6, exercised 2026-07-30): changed
    // `CodeBlockView.maximumExpandedHeight` to 640, rebuilt, then ran
    // `.build/debug/continuum-revived --ui-geometry-check`; exit 1:
    // "FAIL: long fenced code was not capped at 320.0pt (measured 640.0)".
    // The mutation was reverted and the same check passed.

    /// Deterministic P3.7 gate through the frozen production registry and
    /// default host. Agent identity is bound inside action capabilities, never
    /// exposed to the renderer context or semantic document.
    private static func checkToolAndCommandRenderers() throws -> Int {
        func id(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }
        func visibleStrings(in view: NSView) -> [String] {
            let own: [String]
            if let field = view as? NSTextField {
                own = [field.stringValue]
            } else if let button = view as? NSButton {
                own = [button.title, button.toolTip ?? ""]
            } else if let text = view as? NSTextView {
                own = [text.string]
            } else {
                own = []
            }
            return own + view.subviews.flatMap(visibleStrings)
        }

        guard try AgentBlockRendererRegistry.production.renderer(for: .toolCall) is ToolCallRenderer,
              try AgentBlockRendererRegistry.production.renderer(for: .commandOutput) is CommandOutputRenderer else {
            throw fail("production registry did not resolve tool and command-output renderers")
        }

        let agentA = AgentID(rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        let agentB = AgentID(rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        let store = DisclosureStateStore()
        var semanticActions: [AgentRenderAction] = []
        var presentationInvalidations: [AgentNodeID] = []
        let actionsA = store.renderActions(
            for: agentA,
            perform: { semanticActions.append($0) },
            invalidatePresentation: { presentationInvalidations.append($0) }
        )
        let actionsB = store.renderActions(for: agentB)
        let contextA = AgentRenderContext(actions: actionsA, tokens: .transcript, appearance: .dark)
        let contextB = AgentRenderContext(actions: actionsB, tokens: .transcript, appearance: .dark)

        let secret = "PRIVATE-RAW-ARGUMENT-CWD"
        let toolID = id("tool-operation")
        let completedTool = AgentBlock(
            id: toolID, revision: 1, kind: .toolCall,
            payload: .toolCall(.init(
                name: "Read files\nignored provider detail",
                summary: "Inspected the semantic renderer files.",
                arguments: .object(["cwd": .string(secret)]),
                status: .completed
            ))
        )
        let collapsedHeight: CGFloat
        let toolHost = AgentBlockHostView()
        collapsedHeight = try toolHost.measuredHeight(for: completedTool, width: 320, context: contextA)
        toolHost.frame = NSRect(x: 0, y: 0, width: 320, height: collapsedHeight)
        try toolHost.apply(block: completedTool, context: contextA)
        toolHost.layoutSubtreeIfNeeded()
        guard let toolView = toolHost.rendererView as? ToolCallView,
              collapsedHeight == ToolCallView.rowHeight,
              !toolView.isExpanded,
              toolView.summaryLabel.isHidden,
              toolView.titleLabel.stringValue == "Read files",
              toolView.statusLabel.stringValue == "✓ Completed",
              !visibleStrings(in: toolView).contains(where: { $0.contains(secret) }) else {
            throw fail("routine tool did not collapse safely with textual completed status or exposed raw arguments")
        }

        toolView.disclosureButton.performClick(nil)
        let keyA = ToolDisclosureKey(agentID: agentA, blockID: toolID)
        guard toolView.isExpanded, store.explicitState(for: keyA) == true else {
            throw fail("tool disclosure did not persist its explicit expanded state")
        }
        guard presentationInvalidations == [toolID],
              toolHost.measurementCache.cachedMeasurementCount == 0 else {
            throw fail("tool disclosure toggle did not notify layout or evict its cached measurement")
        }
        let expandedHeight = try toolHost.measuredHeight(for: completedTool, width: 320, context: contextA)
        toolHost.frame.size.height = expandedHeight
        toolHost.layoutSubtreeIfNeeded()
        toolView.layoutSubtreeIfNeeded()
        guard expandedHeight > collapsedHeight,
              toolHost.measurementCache.cachedMeasurementCount == 1,
              toolView.summaryLabel.frame.maxY <= toolView.bounds.maxY + 0.5 else {
            throw fail("live tool disclosure did not remeasure and lay out its expanded summary")
        }

        let recreatedHost = AgentBlockHostView()
        recreatedHost.frame = NSRect(x: 0, y: 0, width: 320, height: expandedHeight)
        try recreatedHost.apply(block: completedTool, context: contextA)
        guard let recreatedView = recreatedHost.rendererView as? ToolCallView,
              recreatedView.isExpanded, !recreatedView.summaryLabel.isHidden else {
            throw fail("explicit disclosure did not survive renderer-view recreation for the same block")
        }

        let otherAgentHost = AgentBlockHostView()
        try otherAgentHost.apply(block: completedTool, context: contextB)
        guard let otherAgentView = otherAgentHost.rendererView as? ToolCallView,
              !otherAgentView.isExpanded,
              store.explicitState(for: ToolDisclosureKey(agentID: agentB, blockID: toolID)) == nil else {
            throw fail("tool disclosure leaked across agents sharing a block ID")
        }

        let otherToolID = id("tool-operation-other")
        let otherTool = AgentBlock(
            id: otherToolID, revision: 1, kind: .toolCall,
            payload: .toolCall(.init(name: "Search", summary: "Found matches", status: .completed))
        )
        let staleView = recreatedView
        try recreatedHost.apply(block: otherTool, context: contextA)
        guard let otherView = recreatedHost.rendererView as? ToolCallView, !otherView.isExpanded else {
            throw fail("reused tool host carried disclosure state to another block")
        }
        staleView.disclosureButton.performClick(nil)
        guard store.explicitState(for: keyA) == true else {
            throw fail("detached tool view retained an active disclosure capability")
        }
        try recreatedHost.apply(block: completedTool, context: contextA)
        guard (recreatedHost.rendererView as? ToolCallView)?.isExpanded == true else {
            throw fail("tool disclosure did not restore after host reuse returned to the block")
        }

        let failedTool = AgentBlock(
            id: id("tool-failed"), revision: 1, kind: .toolCall,
            payload: .toolCall(.init(name: "Compile", summary: "Compiler returned an error.", status: .failed))
        )
        let failedToolHost = AgentBlockHostView()
        try failedToolHost.apply(block: failedTool, context: contextA)
        guard let failedToolView = failedToolHost.rendererView as? ToolCallView,
              failedToolView.isExpanded,
              failedToolView.statusLabel.stringValue == "! Failed",
              !failedToolView.summaryLabel.isHidden else {
            throw fail("failed tool did not expand by default with glyph-and-text status")
        }

        let outputID = id("command-output")
        let output = "line one\n    indented result\n"
        let failedOutput = AgentBlock(
            id: outputID, revision: 1, kind: .commandOutput,
            payload: .commandOutput(.init(text: output, exitCode: 7, status: .failed))
        )
        let outputHost = AgentBlockHostView()
        let outputHeight = try outputHost.measuredHeight(for: failedOutput, width: 320, context: contextA)
        outputHost.frame = NSRect(x: 0, y: 0, width: 320, height: outputHeight)
        try outputHost.apply(block: failedOutput, context: contextA)
        outputHost.layoutSubtreeIfNeeded()
        guard let outputView = outputHost.rendererView as? CommandOutputView,
              outputView.isExpanded,
              !outputView.scrollView.isHidden,
              outputView.statusLabel.stringValue == "! Failed, exit 7",
              outputView.outputTextView.string == output else {
            throw fail("failed command output lost exact text, expansion, or glyph-and-text exit status")
        }
        let pasteboard = NSPasteboard(name: .init("continuum.command-output-check.\(UUID().uuidString)"))
        outputView.copyEntireOutput(to: pasteboard)
        guard pasteboard.string(forType: .string) == output else {
            throw fail("command-output copy changed indentation or trailing newline")
        }

        let longOutput = (0..<100).map { "line \($0) " + String(repeating: "x", count: 80) }.joined(separator: "\n") + "\n"
        let longFailedOutput = AgentBlock(
            id: outputID, revision: 2, kind: .commandOutput,
            payload: .commandOutput(.init(text: longOutput, exitCode: 7, status: .failed))
        )
        let cappedHeight = try outputHost.measuredHeight(for: longFailedOutput, width: 320, context: contextA)
        let expectedCap = CommandOutputView.rowHeight
            + CGFloat(Space.xxl + Space.xs)
            + CommandOutputView.maximumOutputHeight
            + CommandOutputView.outputBottomInset
        guard cappedHeight == expectedCap else {
            throw fail("command output exceeded its capped detail height: \(cappedHeight) vs \(expectedCap)")
        }
        outputHost.frame = NSRect(x: 0, y: 0, width: 320, height: cappedHeight)
        try outputHost.apply(block: longFailedOutput, context: contextA)
        outputHost.layoutSubtreeIfNeeded()
        outputView.layoutSubtreeIfNeeded()
        guard outputView.outputTextView.string == longOutput,
              outputView.scrollView.hasVerticalScroller,
              outputView.scrollView.hasHorizontalScroller,
              outputView.outputTextView.frame.height > outputView.scrollView.contentSize.height else {
            throw fail("long command output did not preserve exact text inside capped scrolling")
        }

        let completedOutput = AgentBlock(
            id: id("command-output-complete"), revision: 1, kind: .commandOutput,
            payload: .commandOutput(.init(text: "ok\n", exitCode: 0, status: .completed))
        )
        let completedOutputHost = AgentBlockHostView()
        let completedOutputHeight = try completedOutputHost.measuredHeight(
            for: completedOutput, width: 320, context: contextA
        )
        try completedOutputHost.apply(block: completedOutput, context: contextA)
        guard let completedOutputView = completedOutputHost.rendererView as? CommandOutputView,
              completedOutputHeight == CommandOutputView.rowHeight,
              !completedOutputView.isExpanded,
              completedOutputView.scrollView.isHidden,
              completedOutputView.copyButton.isHidden,
              completedOutputView.statusLabel.stringValue == "✓ Completed, exit 0" else {
            throw fail("routine completed command output did not collapse with textual exit status")
        }

        let presentations: [(AgentItemStatus, String, String)] = [
            (.pending, "○", "Pending"), (.inProgress, "◐", "In progress"),
            (.completed, "✓", "Completed"), (.failed, "!", "Failed"),
            (.cancelled, "–", "Cancelled"), (.interrupted, "!", "Interrupted"),
        ]
        guard presentations.allSatisfy({ item in
            let value = item.0.agentToolStatusPresentation
            return value.glyph == item.1 && value.label == item.2
        }), semanticActions.isEmpty, presentationInvalidations == [toolID] else {
            throw fail("tool statuses lost non-color semantics or disclosure emitted an agent action/stale layout invalidation")
        }
        return presentations.count + 4
    }

    /// P3.9 gate for explicit provider requests, exceptional content, and the
    /// mandatory payload-blind fallback through production reusable hosts.
    private static func checkExceptionalRenderers() throws -> Int {
        func id(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }
        func visibleStrings(in view: NSView) -> [String] {
            let own: [String]
            if let field = view as? NSTextField { own = [field.stringValue] }
            else if let button = view as? NSButton { own = [button.title, button.toolTip ?? ""] }
            else if let text = view as? NSTextView { own = [text.string] }
            else { own = [] }
            return own + view.subviews.flatMap(visibleStrings)
        }
        let registry = AgentBlockRendererRegistry.production
        let futureKind = AgentBlockKind(rawValue: "provider.future-request-shaped")!
        guard try registry.renderer(for: .approval) is ApprovalRenderer,
              try registry.renderer(for: .question) is QuestionRenderer,
              try registry.renderer(for: .error) is ErrorNoticeRenderer,
              try registry.renderer(for: .notice) is ErrorNoticeRenderer,
              try registry.renderer(for: .unknown) is AgentUnknownBlockRenderer,
              try registry.renderer(for: futureKind) is AgentUnknownBlockRenderer else {
            throw fail("exceptional semantic families did not resolve to production renderers/fallback")
        }

        var actions: [AgentRenderAction] = []
        let context = AgentRenderContext(
            actions: AgentRenderActions { actions.append($0) },
            tokens: .transcript,
            appearance: .dark
        )
        let approval = AgentBlock(
            id: id("approval-first"), revision: 1, kind: .approval,
            payload: .approval(.init(
                requestID: "provider-request-approve",
                prompt: [.text("Allow the provider-enforced operation?")],
                status: .pending,
                choices: ["Approve", "Deny"]
            ))
        )
        let approvalHost = AgentBlockHostView()
        let approvalHeight = try approvalHost.measuredHeight(for: approval, width: 320, context: context)
        approvalHost.frame = NSRect(x: 0, y: 0, width: 320, height: approvalHeight)
        try approvalHost.apply(block: approval, context: context)
        approvalHost.layoutSubtreeIfNeeded()
        guard let approvalView = approvalHost.rendererView as? AgentRequestView,
              approvalView.choiceButtons.count == 2,
              approvalView.accessibilityRole() == .group,
              approvalView.choiceButtons.allSatisfy({ $0.frame.maxY <= approvalView.bounds.maxY + 0.5 }) else {
            throw fail("explicit approval did not render bounded custom choices and accessibility")
        }
        let staleApprovalButton = approvalView.choiceButtons[0]
        staleApprovalButton.performClick(nil)
        guard actions.count == 1,
              case .submitResponse(requestID: "provider-request-approve", value: "Approve") = actions[0] else {
            throw fail("approval response lost its opaque provider request identity")
        }

        let secondApproval = AgentBlock(
            id: id("approval-second"), revision: 1, kind: .approval,
            payload: .approval(.init(
                requestID: "provider-request-second",
                prompt: [.text("A different explicit request")],
                status: .inProgress,
                choices: ["Continue"]
            ))
        )
        try approvalHost.apply(block: secondApproval, context: context)
        staleApprovalButton.performClick(nil)
        guard actions.count == 1,
              let secondApprovalView = approvalHost.rendererView as? AgentRequestView,
              secondApprovalView.choiceButtons.count == 1 else {
            throw fail("detached approval choice retained an active prior-request capability")
        }
        secondApprovalView.choiceButtons[0].performClick(nil)
        guard actions.count == 2,
              case .submitResponse(requestID: "provider-request-second", value: "Continue") = actions[1] else {
            throw fail("reused approval host did not route only the current request")
        }

        let resolvedApproval = AgentBlock(
            id: secondApproval.id, revision: 2, kind: .approval,
            payload: .approval(.init(
                requestID: "provider-request-second",
                prompt: [.text("A different explicit request")],
                status: .completed,
                choices: ["Continue"]
            ))
        )
        let staleResolvedButton = secondApprovalView.choiceButtons[0]
        try approvalHost.apply(block: resolvedApproval, context: context)
        staleResolvedButton.performClick(nil)
        guard actions.count == 2,
              (approvalHost.rendererView as? AgentRequestView)?.choiceButtons.isEmpty == true else {
            throw fail("resolved approval retained a response control or stale choice action")
        }

        let question = AgentBlock(
            id: id("question-history"), revision: 1, kind: .question,
            payload: .question(.init(
                prompt: [.text("Readable historical question without a request capability")],
                status: .pending,
                choices: ["Must not become an action"]
            ))
        )
        let questionHost = AgentBlockHostView()
        try questionHost.apply(block: question, context: context)
        guard let questionView = questionHost.rendererView as? AgentRequestView,
              questionView.choiceButtons.isEmpty,
              visibleStrings(in: questionView).contains(where: { $0.contains("Readable historical question") }) else {
            throw fail("request-less question fabricated an action or lost readable history")
        }

        let errorBlock = AgentBlock(
            id: id("recoverable-error"), revision: 1, kind: .error,
            payload: .error(.init(message: "The provider connection closed.", code: "transport.closed", isRecoverable: true))
        )
        let errorHost = AgentBlockHostView()
        let errorHeight = try errorHost.measuredHeight(for: errorBlock, width: 320, context: context)
        errorHost.frame = NSRect(x: 0, y: 0, width: 320, height: errorHeight)
        try errorHost.apply(block: errorBlock, context: context)
        errorHost.layoutSubtreeIfNeeded()
        guard let errorView = errorHost.rendererView as? AgentErrorNoticeView,
              !errorView.retryButton.isHidden, !errorView.copyButton.isHidden,
              errorView.retryButton.frame.maxY <= errorView.bounds.maxY + 0.5,
              errorView.accessibilityLabel() == "Error" else {
            throw fail("recoverable error lost bounded retry/copy actions or accessibility")
        }
        let staleRetry = errorView.retryButton
        let staleCopy = errorView.copyButton
        staleRetry.performClick(nil)
        staleCopy.performClick(nil)
        guard actions.count == 4,
              case .retry(blockID: errorBlock.id) = actions[2],
              case .copy(blockID: errorBlock.id) = actions[3] else {
            throw fail("error controls did not emit block-scoped retry and copy intents")
        }

        let notice = AgentBlock(
            id: id("ordinary-notice"), revision: 1, kind: .notice,
            payload: .notice(.init(message: [.text("Provider session resumed.")], status: .completed))
        )
        try errorHost.apply(block: notice, context: context)
        staleRetry.performClick(nil)
        staleCopy.performClick(nil)
        guard actions.count == 4,
              let noticeView = errorHost.rendererView as? AgentErrorNoticeView,
              noticeView.retryButton.isHidden, noticeView.copyButton.isHidden,
              visibleStrings(in: noticeView).contains("Provider session resumed.") else {
            throw fail("notice acquired error actions or detached error controls remained active")
        }

        let secret = "OPAQUE-SENTINEL-PRIVATE-ARGUMENT"
        let unknown = AgentBlock(
            id: id("unknown-provider-block"), revision: 1, kind: futureKind,
            payload: .opaque(.init(
                debugLabel: "approval: \(secret)",
                value: .object(["requestID": .string(secret), "markdown": .string("- [ ] Approve")])
            ))
        )
        let unknownHost = AgentBlockHostView()
        try unknownHost.apply(block: unknown, context: context)
        guard let unknownView = unknownHost.rendererView as? AgentUnknownBlockView,
              unknownView.summaryLabel.stringValue == "Unsupported content: provider.future-request-shaped",
              unknownView.accessibilityLabel() == "Unsupported content: provider.future-request-shaped",
              !visibleStrings(in: unknownView).contains(where: { $0.contains(secret) || $0.contains("Approve") }),
              unknownView.subviews.compactMap({ $0 as? NSButton }).isEmpty,
              actions.count == 4 else {
            throw fail("unknown fallback exposed opaque/request-shaped data or fabricated an action")
        }

        let legacyRequest = try JSONDecoder().decode(
            AgentRequestPayload.self,
            from: Data(#"{"prompt":[{"text":{"_0":"legacy"}}],"status":"pending","choices":[]}"#.utf8)
        )
        guard legacyRequest.requestID == nil else {
            throw fail("request payload did not preserve backward decoding without request identity")
        }
        return 6
    }

    // Negative witness (P3.9): mutate the unknown fallback summary to include
    // opaque debugLabel; the sentinel privacy assertion above must fail.

    // Negative witness (P3.7): the coordinator records a final-code mutation of
    // the completed-tool default and the real geometry assertion beside this gate.

    // Negative witness (P3.4, exercised 2026-07-30): changed
    // `UserPromptView.layout()` to right-align `proseView` at 72% of the surface,
    // rebuilt, then ran `.build/debug/continuum-revived --ui-geometry-check`;
    // exit 1: "FAIL: user prompt became right-aligned instead of sharing the prose
    // leading edge". The mutation was then reverted and the same check passed.

    /// Deterministic P3.2 gate. A durable final-code mutation witness is recorded
    /// by the coordinator alongside this check's positive evidence.
    private static func checkReusableAgentBlockHost() throws {
        let renderer = BlockHostProbeRenderer(kind: .paragraph)
        let headingRenderer = BlockHostProbeRenderer(kind: .heading)
        let registry = AgentBlockRendererRegistry()
        try registry.register(renderer, for: .paragraph)
        try registry.register(headingRenderer, for: .heading)
        try registry.setFallback(AgentUnknownBlockRenderer())
        try registry.freeze()

        var actions: [String] = []
        func context(_ name: String, appearance: TokenTheme) -> AgentRenderContext {
            AgentRenderContext(
                actions: AgentRenderActions { action in
                    if case let .copy(blockID) = action { actions.append("\(name):\(blockID.rawValue)") }
                },
                tokens: .transcript,
                appearance: appearance
            )
        }
        let firstID = AgentNodeID(rawValue: "geometry-host-first")!
        let secondID = AgentNodeID(rawValue: "geometry-host-second")!
        let first = AgentBlock(id: firstID, revision: 1, kind: .paragraph, payload: .paragraph([.text("first")]))
        let revised = AgentBlock(id: firstID, revision: 2, kind: .paragraph, payload: .paragraph([.text("revised")]))
        let second = AgentBlock(id: secondID, revision: 1, kind: .paragraph, payload: .paragraph([.text("second")]))
        let changedKind = AgentBlock(
            id: secondID, revision: 2, kind: .heading,
            payload: .heading(level: 2, content: [.text("second heading")])
        )
        let dark = context("old", appearance: .dark)

        let host = AgentBlockHostView(registry: registry)
        try host.apply(block: first, context: dark)
        guard let initialView = host.rendererView else { throw fail("block host did not install a renderer view") }
        let initialIdentity = ObjectIdentifier(initialView)
        try host.apply(block: revised, context: dark)
        guard host.rendererView.map(ObjectIdentifier.init) == initialIdentity else {
            throw fail("same block ID/kind revision update replaced its renderer view")
        }

        host.setInteractionState(hovered: true, selected: true, disclosureExpanded: true)
        let staleView = initialView
        try host.apply(block: second, context: context("new", appearance: .dark))
        guard let replacement = host.rendererView as? BlockHostProbeView,
              ObjectIdentifier(replacement) != initialIdentity else {
            throw fail("reusing a block host for another ID retained its renderer view")
        }
        guard replacement.renderedText == "second",
              replacement.textField.stringValue != "revised" else {
            throw fail("reusing a block host left stale text in its renderer view: \(replacement.renderedText)")
        }
        guard !host.isBlockHovered, !host.isBlockSelected, !host.isDisclosureExpanded else {
            throw fail("reusing a block host leaked hover, selection, or disclosure state")
        }
        guard staleView.accessibilityLabel() == nil, staleView.superview == nil else {
            throw fail("reusing a block host left stale accessibility content or its old view behind")
        }
        (staleView as? BlockHostProbeView)?.invokeCopy()
        guard actions.isEmpty else {
            throw fail("a detached renderer view retained an active action: \(actions)")
        }
        replacement.invokeCopy()
        guard actions == ["new:\(secondID.rawValue)"] else {
            throw fail("reusing a block host retained a stale render action: \(actions)")
        }

        host.setInteractionState(hovered: true, selected: true, disclosureExpanded: true)
        let preKindChangeIdentity = ObjectIdentifier(replacement)
        try host.apply(block: changedKind, context: context("heading", appearance: .dark))
        guard let headingView = host.rendererView as? BlockHostProbeView,
              ObjectIdentifier(headingView) != preKindChangeIdentity,
              host.representedKind == .heading,
              headingView.renderedText == "second heading" else {
            throw fail("same-ID kind change did not replace and refresh its renderer view")
        }
        guard !host.isBlockHovered, !host.isBlockSelected, !host.isDisclosureExpanded else {
            throw fail("same-ID kind change leaked hover, selection, or disclosure state")
        }
        replacement.invokeCopy()
        guard actions == ["new:\(secondID.rawValue)"] else {
            throw fail("a kind-superseded renderer view retained an active action: \(actions)")
        }
        headingView.invokeCopy()
        guard actions == ["new:\(secondID.rawValue)", "heading:\(secondID.rawValue)"] else {
            throw fail("same-ID kind change retained a stale render action: \(actions)")
        }

        let firstAsHeading = AgentBlock(
            id: firstID, revision: 1, kind: .heading,
            payload: .heading(level: 2, content: [.text("first heading")])
        )
        let cache = AgentBlockMeasurementCache()
        _ = cache.height(for: first, width: 100.1, context: dark, renderer: renderer)
        _ = cache.height(for: first, width: 100.2, context: dark, renderer: renderer)
        _ = cache.height(for: first, width: 101.2, context: dark, renderer: renderer)
        _ = cache.height(for: revised, width: 101.2, context: dark, renderer: renderer)
        _ = cache.height(for: revised, width: 101.2, context: context("light", appearance: .light), renderer: renderer)
        _ = cache.height(
            for: revised, width: 101.2, context: dark,
            contentSizePolicy: AgentContentSizePolicy(scaleBucket: 125), renderer: renderer
        )
        _ = cache.height(for: firstAsHeading, width: 100.1, context: dark, renderer: headingRenderer)
        try expectIsolatedBlockMeasurements(
            cacheCount: cache.cachedMeasurementCount,
            rendererCount: renderer.measureCount + headingRenderer.measureCount
        )

        host.resetForReuse()
        guard host.rendererView == nil, host.representedID == nil, host.representedRevision == nil else {
            throw fail("resetForReuse retained represented block state")
        }
        headingView.invokeCopy()
        guard actions == ["new:\(secondID.rawValue)", "heading:\(secondID.rawValue)"] else {
            throw fail("resetForReuse left its detached renderer action active: \(actions)")
        }
    }

    private static func expectIsolatedBlockMeasurements(
        cacheCount: Int,
        rendererCount: Int
    ) throws {
        guard cacheCount == 6, rendererCount == 6 else {
            throw fail("block measurement cache collapsed ID/kind/entry-role/revision/width/appearance/content-size/presentation-revision keys (cache \(cacheCount), renderer \(rendererCount), expected 6)")
        }
    }

}

@MainActor
private final class BlockHostProbeView: NSView {
    let textField = NSTextField(labelWithString: "")
    var blockID: AgentNodeID?
    var actions: AgentRenderActions = .disabled
    var renderedText: String {
        get { textField.stringValue }
        set { textField.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func invokeCopy() {
        guard let blockID else { return }
        actions.perform(.copy(blockID: blockID))
    }
}

@MainActor
private final class BlockHostProbeRenderer: AgentBlockRendering {
    let kind: AgentBlockKind
    private(set) var measureCount = 0

    init(kind: AgentBlockKind) {
        self.kind = kind
    }

    func makeView() -> NSView {
        let view = BlockHostProbeView(frame: .zero)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        return view
    }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? BlockHostProbeView else { return }
        view.blockID = block.id
        view.actions = context.actions
        switch block.payload {
        case let .paragraph(content), let .heading(_, content):
            view.renderedText = content.compactMap { inline in
                if case let .text(text) = inline { return text }
                return nil
            }.joined()
        default:
            view.renderedText = "unexpected payload"
        }
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        measureCount += 1
        return width + CGFloat(block.revision) + CGFloat(context.appearance == .dark ? 1 : 2)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        view.setAccessibilityLabel("probe \(block.id.rawValue) revision \(block.revision)")
    }
}
