import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

@MainActor
private final class CompactStatusProbeThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    private(set) var snapshotPhase: CGFloat = 0
    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Injected thinking indicator probe")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func startAnimating() {}
    func stopAnimating() {}
    func setReducedMotion(_ enabled: Bool) {}
    func setSnapshotPhase(_ phase: CGFloat) { snapshotPhase = phase }
}

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

        let sidebarResizeAssertions = try checkSidebarWidthResizePolicy()
        print("UIProbeGeometry: sidebar resize policy, delegate, cursor/AX, restore, and write timing held across \(sidebarResizeAssertions) assertions")
        // P5.5 acceptance: the legacy card-stack transcript and its approval dock
        // are deleted; the v2 composition root is gated by
        // `checkLiveV2AgentTileLayout()` below (320/480/560/640/900 x both themes,
        // fills, clipping, constraints, footer effort sizing/truncation) and the semantic
        // transcript by `checkTranscriptCollectionList()`.
        try checkReusableAgentBlockHost()
        let composerCases = try checkGrowingComposerLayout()
        let choiceCases = try checkChoicePopover()
        try checkAgentTileHeaderShell()
        let compactStatusAssertions = try checkCompactStatusRow()
        print("UIProbeGeometry: compact bottom status row held \(compactStatusAssertions) geometry, appearance, contrast, state, accessibility, and compression assertions at 320/480/560/wide in both appearances")
        try checkLiveV2AgentTileLayout()
        let transcriptLiveHosts = try checkTranscriptCollectionList()
        let streamingApplies = try checkIncrementalTranscriptBehavior()
        let proseRows = try checkAssistantProseRenderer()
        let userPromptRows = try checkUserPromptRenderer()
        let codeRows = try checkCodeBlockRenderer()
        let operationRows = try checkToolAndCommandRenderers()
        let mediaRows = try checkImageRenderers()
        let exceptionalRows = try checkExceptionalRenderers()
        let reasoningDisclosureRows = try checkCompletedReasoningDisclosure()
        // P0.4: the inbox measured at the widths it ships at, truncation gated
        // by drawable width against an explicit expected-defect table.
        let sidebarHeightAssertions = try checkSidebarContentDerivedHeights()
        let sidebarGate = try checkSidebarTruncationGate()
        print("UIProbeGeometry: content-derived sidebar row heights held in \(sidebarHeightAssertions) live width/appearance cases")
        print(String(
            format: "UIProbeGeometry: sidebar truncation gate measured %d labels at min/default/wide in both appearances; %d truncations, all in the expected table, none healed unrecorded",
            sidebarGate.measured, sidebarGate.truncated
        ))
        print(String(
            format: "UIProbeGeometry: reusable block host identity/reset and 8-dimensional measurement key gated; composer grows through %d width/draft cases with an eight-visual-line cap and stable constraints; custom choice popover gates %d keyboard, disabled, accessibility-state, appearance, and screen-placement cases; live v2 tile gated at 320/480/560/640/900 in both appearances with footer truncation measured across the required effort values; transcript collection virtualized 10000 rows into %d live hosts while preserving unaffected identity; 5000 streaming deltas coalesced into %d visual apply with anchored/selection-safe scrolling, copy, and ordered accessibility; assistant prose wraps %d semantic rows, user prompt wraps %d semantic rows, fenced code preserves %d exact lines, %d tool/command states preserve scoped disclosure, %d image/gallery states preserve opaque local media actions, %d exceptional states preserve request identity and opaque privacy, and %d completed-reasoning disclosure states preserve scoped expansion at 320pt",
            composerCases, choiceCases, transcriptLiveHosts, streamingApplies, proseRows, userPromptRows, codeRows, operationRows, mediaRows, exceptionalRows, reasoningDisclosureRows
        ))
    }

    // MARK: - Compact bottom status row

    private static func checkCompactStatusRow() throws -> Int {
        var assertions = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
            guard condition() else { throw fail(message()) }
            assertions += 1
        }

        let now = Date(timeIntervalSince1970: 1_000)
        let checkout = URL(fileURLWithPath: "/Users/qa/Projects/continuum", isDirectory: true)
        let home = AgentHome(projectId: nil, projectRoot: checkout, checkoutRoot: checkout)
        let longInside = AgentLocationSnapshot(
            home: home,
            whereDirectory: checkout.appendingPathComponent(
                "Sources/ContinuumRevived/Canvas/AgentActivity/Deeply/Nested/Status/Row/Fixture",
                isDirectory: true))
        let external = AgentLocationSnapshot(
            home: home,
            whereDirectory: URL(fileURLWithPath: "/Users/qa/References/neighbor-worktree", isDirectory: true))

        let known = AgentContextWindowSnapshot(
            usedTokens: 48_000, maxTokens: 128_000,
            inputTokens: 1_200, outputTokens: 640, cacheReadTokens: 12_000,
            totalCostUsd: 0.1234, observedAt: now,
            source: .providerSessionStats, freshness: .live)
        let warning = AgentContextWindowSnapshot(
            usedTokens: 102_400, maxTokens: 128_000,
            inputTokens: 3_000, outputTokens: 1_000, cacheWriteTokens: 800,
            totalProcessedTokens: 4_800, observedAt: now,
            source: .providerSessionStats, freshness: .live)
        let critical = AgentContextWindowSnapshot(
            usedTokens: 120_000, maxTokens: 128_000,
            totalCostUsd: 1.2345, observedAt: now,
            source: .providerSessionStats, freshness: .live)
        let unknown = AgentContextWindowSnapshot(
            inputTokens: 400, outputTokens: 50, cacheReadTokens: 900,
            totalCostUsd: 0.0100, observedAt: now,
            source: .piMessageUsage, freshness: .live)
        let stale = AgentContextWindowSnapshot(
            usedTokens: 64_000, maxTokens: 128_000,
            inputTokens: 600, outputTokens: 90, observedAt: now.addingTimeInterval(-800),
            source: .providerSessionStats, freshness: .stale)

        let statePresentations: [(AgentRadialContextMeterState, AgentRadialContextMeterPresentation)] = [
            (.known, AgentRadialContextMeterPresenter.present(known)),
            (.warning, AgentRadialContextMeterPresenter.present(warning)),
            (.critical, AgentRadialContextMeterPresenter.present(critical)),
            (.unknown, AgentRadialContextMeterPresenter.present(unknown)),
            (.stale, AgentRadialContextMeterPresenter.present(stale)),
        ]
        for (state, presentation) in statePresentations {
            try require(presentation.state == state, "compact status context state \(state.rawValue) did not present truthfully")
            try require(presentation.detailText.contains("Authoritative context"), "compact status context detail omits authoritative context line for \(state.rawValue)")
            try require(presentation.detailText.contains("Per-message/cache/cost fields"), "compact status context detail omits usage/cache/cost distinction for \(state.rawValue)")
            try require(presentation.detailText.contains("Freshness"), "compact status context detail omits freshness for \(state.rawValue)")
        }
        try require(statePresentations.first { $0.0 == .unknown }?.1.fraction == nil,
                    "compact status unknown context fabricated an occupancy fraction")
        try require(!(statePresentations.first { $0.0 == .unknown }?.1.label.contains("0%") ?? true),
                    "compact status unknown context displayed fabricated 0%")
        try require(statePresentations.first { $0.0 == .warning }?.1.warningMarker != nil
                        && statePresentations.first { $0.0 == .warning }?.1.label.contains("%") == true,
                    "compact status warning relies on color alone")
        try require(statePresentations.first { $0.0 == .critical }?.1.label.contains("!") == true,
                    "compact status critical lacks non-color marker")
        try require(statePresentations.first { $0.0 == .stale }?.1.label.contains("stale") == true,
                    "compact status stale context lacks visible stale state")

        let tokenPairs: [TokenPair] = [
            TokenPair(foreground: "compact.location", background: "tileChrome", color: TextToken.textSecondary.color, backgroundColor: SurfaceToken.tileChrome.color, floor: DesignTokens.textFloor),
            TokenPair(foreground: "compact.working", background: "tileChrome", color: AccentToken.accentWorking.color, backgroundColor: SurfaceToken.tileChrome.color, floor: DesignTokens.textFloor),
            TokenPair(foreground: "compact.warning", background: "tileChrome", color: AccentToken.accentApproval.color, backgroundColor: SurfaceToken.tileChrome.color, floor: DesignTokens.textFloor),
            TokenPair(foreground: "compact.critical", background: "tileChrome", color: AccentToken.accentFailed.color, backgroundColor: SurfaceToken.tileChrome.color, floor: DesignTokens.textFloor),
            TokenPair(foreground: "compact.known", background: "tileChrome", color: AccentToken.accentDone.color, backgroundColor: SurfaceToken.tileChrome.color, floor: DesignTokens.textFloor),
            TokenPair(foreground: "compact.boundary", background: "tileChrome", color: LineToken.border.color, backgroundColor: SurfaceToken.tileChrome.color, floor: DesignTokens.lineFloor),
        ]
        for pair in tokenPairs {
            for theme in [TokenTheme.light, .dark] {
                try require(pair.ratio(for: theme) >= pair.floor,
                            "compact status contrast \(pair.foreground) on \(pair.background) failed in \(theme.rawValue)")
            }
        }

        let sizes: [(String, CGFloat, AgentCompactStatusPresentation)] = [
            ("320", 320, AgentCompactStatusPresentation.present(
                location: longInside, projectName: "continuum", status: .working,
                startedAt: now.addingTimeInterval(-65), now: now, contextWindow: known)),
            ("480", 480, AgentCompactStatusPresentation.present(
                location: external, projectName: "continuum", status: .needsAttention,
                startedAt: now.addingTimeInterval(-3_200), now: now, contextWindow: warning)),
            ("560", 560, AgentCompactStatusPresentation.present(
                location: longInside, projectName: "continuum", status: .working,
                startedAt: now.addingTimeInterval(-122), now: now, contextWindow: critical)),
            ("wide", 900, AgentCompactStatusPresentation.present(
                location: longInside, projectName: "continuum", status: .idle,
                startedAt: nil, now: now, contextWindow: unknown)),
        ]

        var appearanceDigests: [String: [String]] = [:]
        for (name, width, presentation) in sizes {
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let probe = try UIProbe.render(
                    UIProbe.Spec(
                        id: "compactStatusRow.\(name).\(appearanceName.rawValue)",
                        size: NSSize(width: width, height: AgentCompactStatusRowView.preferredHeight),
                        appearance: appearanceName)) {
                    let row = AgentCompactStatusRowView(thinkingIndicatorFactory: { CompactStatusProbeThinkingIndicatorView() })
                    row.apply(presentation)
                    return row
                }
                guard let row = probe.view as? AgentCompactStatusRowView else {
                    throw fail("compact status row probe did not return row view")
                }
                try expectNoClipping(row, label: "compactStatusRow@\(name).\(appearanceName.rawValue)")
                try expectNoBrokenRequiredSizeConstraints(row, label: "compactStatusRow@\(name).\(appearanceName.rawValue)")
                try require(row.qaContentFitsBounds, "compact status row content escapes bounds at \(name)/\(appearanceName.rawValue)")
                try require(row.qaActivityAndContextVisible, "compact status row compressed activity/context before location at \(name)/\(appearanceName.rawValue)")
                try require(row.qaLocationCompressionPriority < row.qaActivityCompressionPriority,
                            "compact status row location is not first compression sacrifice")
                try require(row.qaLocationCompressionPriority < row.qaContextCompressionPriority,
                            "compact status row context can compress before location")
                try require(row.qaActivityCompressionPriority >= NSLayoutConstraint.Priority.required.rawValue,
                            "compact status row activity priority is not protected")
                try require(row.qaContextCompressionPriority >= NSLayoutConstraint.Priority.required.rawValue,
                            "compact status row context priority is not protected")
                try require(!row.qaHasVisiblePrefixes, "compact status row leaked Home/Where/What visual prefixes at \(name)")
                try require(row.qaContextMeterSide >= 18 && row.qaContextMeterSide <= 20,
                            "compact status row radial meter side \(row.qaContextMeterSide) outside 18-20pt")
                try require(row.qaContextDetail.contains("Authoritative context"), "compact status row context tooltip missing authoritative context")
                try require(row.qaContextDetail.contains("Per-message/cache/cost fields"), "compact status row context tooltip missing per-message/cache/cost fields")
                try require(row.qaContextDetail.contains("Freshness"), "compact status row context tooltip missing freshness")
                try require(row.qaAccessibilityLabel.contains("Location") && row.qaAccessibilityLabel.contains("Activity") && row.qaAccessibilityLabel.contains("Context"),
                            "compact status row AX label dropped one semantic fact")
                if presentation.activity.showsThinkingIndicator {
                    try require(row.qaThinkingSlotVisible, "compact status row hid injected thinking indicator while working")
                }
                appearanceDigests[name, default: []].append(probe.contentDigest)
            }
        }
        for (name, digests) in appearanceDigests {
            try require(Set(digests).count == 2, "compact status row \(name) aqua/darkAqua render did not differ")
        }
        return assertions
    }

    // MARK: - Sidebar width policy

    /// Covers the pure policy and the actual NSSplitView delegate seam. In
    /// particular, an already-over-limit divider may shrink to any proposed
    /// coordinate without `constrainMaxCoordinate` snapping it to the new ceiling.
    private static func checkSidebarWidthResizePolicy() throws -> Int {
        var assertions = 0
        let divider = 2.0
        let normalWindow = WorkspaceSidebarConfig.contentMinimumWidth + 500 + divider
        let narrowWindow = WorkspaceSidebarConfig.contentMinimumWidth - 40 + divider
        let computedMaximum = WorkspaceSidebarConfig.maximumWidth(
            forWindowWidth: normalWindow, dividerThickness: divider)
        let narrowMaximum = WorkspaceSidebarConfig.maximumWidth(
            forWindowWidth: narrowWindow, dividerThickness: divider)

        func require(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
            guard condition() else { throw fail(message()) }
            assertions += 1
        }

        func makeSplit(windowWidth: Double, sidebarWidth: Double) -> (NSSplitView, WorkspaceSidebarView) {
            let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: 420))
            splitView.isVertical = true
            splitView.dividerStyle = .thin
            let sidebar = WorkspaceSidebarView(
                frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: 420))
            let content = NSView(frame: NSRect(
                x: sidebarWidth + divider, y: 0,
                width: max(0, windowWidth - sidebarWidth - divider), height: 420))
            splitView.addArrangedSubview(sidebar)
            splitView.addArrangedSubview(content)
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
            return (splitView, sidebar)
        }

        try require(
            WorkspaceSidebarConfig.clampedWidth(WorkspaceSidebarConfig.minWidth - 40) == WorkspaceSidebarConfig.minWidth,
            "ui-geometry-check.sidebar-resize.minimum: width escaped the 220 pt floor")
        try require(
            WorkspaceSidebarConfig.clampedWidth(WorkspaceSidebarConfig.defaultWidth) == WorkspaceSidebarConfig.defaultWidth,
            "ui-geometry-check.sidebar-resize.default: default width changed")
        try require(computedMaximum == 500 && computedMaximum > WorkspaceSidebarConfig.maxWidth,
            "ui-geometry-check.sidebar-resize.computed maximum: expected dynamic 500 above legacy 420, got \(computedMaximum)")
        try require(narrowMaximum == WorkspaceSidebarConfig.minWidth,
            "ui-geometry-check.sidebar-resize.narrow maximum: expected sidebar floor, got \(narrowMaximum)")

        let computedGrowth = WorkspaceSidebarConfig.constrainedWidth(
            proposed: computedMaximum + 80, current: WorkspaceSidebarConfig.defaultWidth,
            windowWidth: normalWindow, dividerThickness: divider)
        try require(computedGrowth == computedMaximum,
            "ui-geometry-check.sidebar-resize.computed maximum: growth resolved \(computedGrowth), expected \(computedMaximum)")

        let overLimitGrowth = WorkspaceSidebarConfig.constrainedWidth(
            proposed: 370, current: 360, windowWidth: narrowWindow, dividerThickness: divider)
        try require(overLimitGrowth == 360,
            "ui-geometry-check.sidebar-resize.over-limit growth snapped from 360 to \(overLimitGrowth)")
        let proposedShrink = WorkspaceSidebarConfig.constrainedWidth(
            proposed: 300, current: 360, windowWidth: narrowWindow, dividerThickness: divider)
        try require(proposedShrink == 300,
            "ui-geometry-check.sidebar-resize.over-limit shrink snapped from proposed 300 to \(proposedShrink)")
        let minimumShrink = WorkspaceSidebarConfig.constrainedWidth(
            proposed: WorkspaceSidebarConfig.minWidth - 1, current: 360,
            windowWidth: narrowWindow, dividerThickness: divider)
        try require(minimumShrink == WorkspaceSidebarConfig.minWidth,
            "ui-geometry-check.sidebar-resize.minimum shrink resolved \(minimumShrink)")

        let suiteName = "continuum.sidebar-resize-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw fail("ui-geometry-check.sidebar-resize: could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        WorkspaceSidebarConfig.setWidth(520, defaults: defaults)
        try require(WorkspaceSidebarConfig.resolveWidth(defaults: defaults) == 520,
            "ui-geometry-check.sidebar-resize.restore: computed width above 420 did not survive persistence")

        let (minimumSplit, minimumSidebar) = makeSplit(
            windowWidth: normalWindow, sidebarWidth: WorkspaceSidebarConfig.minWidth)
        _ = minimumSplit
        try require(
            minimumSidebar.resizeDirectionForQA == .growOnly && minimumSidebar.resizeCursorForQA === NSCursor.resizeRight,
            "ui-geometry-check.sidebar-resize.minimum presentation did not expose grow-only cursor state")

        let (maximumSplit, maximumSidebar) = makeSplit(
            windowWidth: normalWindow, sidebarWidth: computedMaximum)
        let liveComputedMaximum = WorkspaceSidebarConfig.maximumWidth(
            forWindowWidth: normalWindow,
            dividerThickness: Double(maximumSplit.dividerThickness))
        maximumSplit.setPosition(liveComputedMaximum, ofDividerAt: 0)
        maximumSplit.layoutSubtreeIfNeeded()
        try require(
            maximumSidebar.resizeDirectionForQA == .shrinkOnly && maximumSidebar.resizeCursorForQA === NSCursor.resizeLeft,
            "ui-geometry-check.sidebar-resize.maximum presentation did not expose shrink-only cursor state (width=\(maximumSidebar.frame.width), direction=\(String(describing: maximumSidebar.resizeDirectionForQA)))")

        let (lockedSplit, lockedSidebar) = makeSplit(
            windowWidth: narrowWindow, sidebarWidth: narrowMaximum)
        _ = lockedSplit
        try require(
            lockedSplit.accessibilityRole() == .splitGroup
                && lockedSidebar.resizeDirectionForQA == .locked
                && lockedSidebar.resizeCursorForQA === NSCursor.operationNotAllowed
                && lockedSidebar.resizeAccessibilityRoleForQA == .splitter
                && lockedSidebar.resizeAccessibilityLabelForQA == "Resize sidebar, cannot grow or shrink",
            "ui-geometry-check.sidebar-resize.locked cursor and accessibility state disagreed")

        let (overLimitSplit, overLimitSidebar) = makeSplit(windowWidth: narrowWindow, sidebarWidth: 360)
        _ = overLimitSplit
        let liveMaximum = overLimitSidebar.maximumResizeCoordinateForQA(1_000)
        let liveShrink = overLimitSidebar.constrainedResizePositionForQA(300)
        let liveGrowth = overLimitSidebar.constrainedResizePositionForQA(370)
        try require(liveMaximum == 360,
            "ui-geometry-check.sidebar-resize.delegate maximum snapped over-limit width to \(String(describing: liveMaximum))")
        try require(liveShrink == 300,
            "ui-geometry-check.sidebar-resize.delegate shrink did not follow 300: \(String(describing: liveShrink))")
        try require(liveGrowth == 360,
            "ui-geometry-check.sidebar-resize.delegate growth was not vetoed in place: \(String(describing: liveGrowth))")

        let (dragSplit, dragSidebar) = makeSplit(
            windowWidth: normalWindow, sidebarWidth: WorkspaceSidebarConfig.defaultWidth)
        var writes: [Double] = []
        dragSidebar.setWidthPersistenceForQA { writes.append($0) }
        dragSidebar.beginResizeForQA()
        dragSplit.setPosition(300, ofDividerAt: 0)
        dragSplit.layoutSubtreeIfNeeded()
        dragSplit.setPosition(320, ofDividerAt: 0)
        dragSplit.layoutSubtreeIfNeeded()
        try require(writes.isEmpty,
            "ui-geometry-check.sidebar-resize.drag wrote \(writes.count) time(s) before resize end")
        dragSidebar.finishResizeForQA()
        dragSidebar.finishResizeForQA()
        try require(writes == [320],
            "ui-geometry-check.sidebar-resize.drag expected one idempotent resize-end write [320], got \(writes)")

        return assertions
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
        width: CGFloat,
        height: CGFloat,
        appearanceName: NSAppearance.Name,
        framePinnedInbox: Bool = false
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
        // Keep the probe at the requested shipping size even after a conditional
        // overlay becomes visible. Without both bounds AppKit may grow the offscreen
        // window to its updated fitting size and a purported 220pt assertion quietly
        // measures the 280pt default instead.
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        // A borderless window may adjust its content view while it is being
        // installed. Re-assert the probe size before Auto Layout gets its first
        // chance to calculate the inbox subtree.
        host.frame = NSRect(origin: .zero, size: size)

        let inbox = AgentInboxView(frame: framePinnedInbox ? host.bounds : .zero)
        host.addSubview(inbox)
        if framePinnedInbox {
            // Conditional overlays change fitting size. A frame-pinned full inbox is
            // the deterministic equivalent of the split-view lane that owns its width
            // in production, so 220pt cannot silently inflate to the 280pt default.
            inbox.autoresizingMask = [.width, .height]
        } else {
            inbox.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                inbox.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                inbox.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                inbox.topAnchor.constraint(equalTo: host.topAnchor),
                inbox.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
        host.layoutSubtreeIfNeeded()
        guard abs(host.bounds.width - width) <= 0.5,
              abs(host.bounds.height - height) <= 0.5,
              inbox.bounds.width > 0, inbox.bounds.height > 0 else {
            throw fail(String(
                format: "sidebar-ux-check@%.0fpt: sized host did not give the inbox a live viewport (host %.1fx%.1f, inbox %.1fx%.1f)",
                width, host.bounds.width, host.bounds.height, inbox.bounds.width, inbox.bounds.height
            ))
        }
        // Pin the scroller before any content is applied: a legacy scroller reserves a
        // lane and narrows every width this probe measures, so leaving it to the
        // machine's preference makes the truncation table machine-dependent. The
        // shipped view deliberately does NOT do this — see `pinScrollerStyleForQA`.
        inbox.pinScrollerStyleForQA()
        // Existing geometry legs assert the normal palette and immediate variant
        // transition. The P6.6 sweep replaces these seams to drive Reduce Motion and
        // Increase Contrast explicitly, so the host setting cannot make an old leg
        // pass or fail by accident.
        inbox.prefersReducedMotion = { false }
        inbox.prefersIncreasedContrast = { false }
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

    private struct IndependentFanoutRemainderExpectation {
        let parentID: UUID
        let hiddenChildIDs: [UUID]
        let hiddenDescendantIDs: [UUID]

        var title: String { "\(hiddenChildIDs.count) more" }
    }

    private struct IndependentFanoutExpectation {
        let visibleIDs: [UUID]
        let remainders: [IndependentFanoutRemainderExpectation]
    }

    /// Independent expectation for the P0.3 fan-out corpus. This deliberately
    /// does not call `boundedForInbox`: the gate knows the defect fixture's one
    /// forty-child parent and calculates the eight survivor ids, hidden subtree
    /// ids and remainder title itself, so a cap that silently changes both the
    /// renderer and its oracle cannot stay green by agreeing with itself.
    private static func independentlyExpectedDefaultFanout(
        _ rows: [AgentInboxRow]
    ) throws -> IndependentFanoutExpectation {
        let sorted = InboxSort.sortForInbox(rows: rows)
        let largeParents = sorted.filter { parent in
            rows.filter { $0.parentId == parent.id }.count > 8
        }
        guard largeParents.count == 1, let parent = largeParents.first else {
            throw fail("sidebar-ux-check.fanout: expected exactly one parent over the independent eight-child cap")
        }
        let children = rows.filter { $0.parentId == parent.id }
        func priority(_ row: AgentInboxRow) -> Int {
            switch row.state {
            case .approval, .input: return 0
            case .failed: return 1
            case .working, .ready: return 2
            }
        }
        let orderedChildren = children.sorted {
            let leftPriority = priority($0)
            let rightPriority = priority($1)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            let leftActive = $0.lastActiveAt ?? $0.createdAt
            let rightActive = $1.lastActiveAt ?? $1.createdAt
            if leftActive != rightActive { return leftActive > rightActive }
            return $0.id.uuidString < $1.id.uuidString
        }
        let selected = orderedChildren.prefix(8)
        let hidden = Array(orderedChildren.dropFirst(8))
        let selectedIDs = Set(selected.map(\.id))
        let childIDs = Set(children.map(\.id))

        func subtreeIDs(startingAt id: UUID) -> [UUID] {
            var result: [UUID] = []
            var visited = Set<UUID>()
            func visit(_ current: UUID) {
                guard visited.insert(current).inserted else { return }
                result.append(current)
                for child in rows where child.parentId == current {
                    visit(child.id)
                }
            }
            visit(id)
            return result
        }

        let remainder = IndependentFanoutRemainderExpectation(
            parentID: parent.id,
            hiddenChildIDs: hidden.map(\.id),
            hiddenDescendantIDs: hidden.flatMap { subtreeIDs(startingAt: $0.id) })
        return IndependentFanoutExpectation(
            visibleIDs: sorted
                .filter { !childIDs.contains($0.id) || selectedIDs.contains($0.id) }
                .map(\.id),
            remainders: [remainder])
    }

    /// The offscreen host is sized for both explicit contracts: the default
    /// capped list with its remainder item, and the expanded list with every
    /// corpus agent. The larger contract wins; a fixed corpus-count height would
    /// either under-materialize the expanded state or hide a bad cap behind slack.
    private static func sidebarProbeHeight(for rows: [AgentInboxRow]) -> CGFloat {
        let sorted = InboxSort.sortForInbox(rows: rows)
        let defaultBounded = InboxSort.boundedForInbox(rows: sorted)
        let expandedBounded = InboxSort.boundedForInbox(
            rows: sorted, expandedParents: Set(InboxSort.parentIds(in: sorted)))
        func tableRows(for bounded: BoundedInbox) -> Int {
            let parts = InboxSort.partition(rows: bounded.rows, now: LabFixtures.inboxNow)
            let shelf = parts.shelfCount > 0 ? 1 : 0
            let page = InboxSort.pageSettled(
                parts.settled, limit: InboxSort.settledPageSize).hasMore ? 1 : 0
            return bounded.rows.count + shelf + page + bounded.remainders.count
        }
        let requiredRows = max(tableRows(for: defaultBounded), tableRows(for: expandedBounded))
        let rowPitch = AgentInboxView.rowHeight + Space.s
        return CGFloat(
            (Double(requiredRows) * rowPitch + AgentInboxView.scopeControlHeight + 160).rounded(.up)
        )
    }

    /// Read the live table's DEFAULT shape before any remainder button is
    /// pressed. The expected cap and remainder are independently derived from
    /// the corpus above; only the shelf heading and history footer are counted as
    /// other non-agent rows. This is deliberately a table-row equation, not an
    /// accessor-only check:
    ///
    ///   table rows = visible agent cells + remainder affordances + section chrome
    ///
    /// A missing remainder can therefore not masquerade as a missing agent cell.
    private static func assertDefaultFanoutAccounting(
        _ probe: SidebarProbeHost,
        rows: [AgentInboxRow],
        expected: IndependentFanoutExpectation,
        label: String
    ) throws {
        guard probe.inbox.isShelfExpandedForQA else {
            throw fail("\(label): default fan-out accounting requires the real shelf to be expanded")
        }
        let expectedVisible = Set(expected.visibleIDs)
        let sorted = InboxSort.sortForInbox(rows: rows)
        let defaultVisibleRows = sorted.filter { expectedVisible.contains($0.id) }
        let parts = InboxSort.partition(rows: defaultVisibleRows, now: LabFixtures.inboxNow)
        let page = InboxSort.pageSettled(parts.settled, limit: InboxSort.settledPageSize)
        let expectedAgentIDs = (parts.active + parts.snoozed + page.shown).map(\.id)
        let expectedAgentCells = expectedAgentIDs.count
        let expectedShelfRows = parts.shelfCount > 0 ? 1 : 0
        let expectedPagingRows = page.hasMore ? 1 : 0
        let expectedNonAgentRows = expectedShelfRows + expectedPagingRows
        let actualRemainders = probe.inbox.fanoutRemainderRowsForQA
        let expectedRemainderIDs = Set(expected.remainders.map(\.parentID))
        let actualRemainderIDs = Set(actualRemainders.map(\.parentId))

        guard expectedAgentIDs == expected.visibleIDs,
              probe.inbox.rowIdsForQA == expectedAgentIDs,
              probe.inbox.qaMaterializedRowCellCount == expectedAgentCells,
              probe.inbox.rowCountForQA == expectedAgentCells else {
            throw fail("\(label): default agent-cell accounting disagreed with the independent cap (live ids \(probe.inbox.rowIdsForQA.count), expected \(expectedAgentCells))")
        }
        guard actualRemainderIDs == expectedRemainderIDs,
              actualRemainders.count == expected.remainders.count,
              probe.inbox.fanoutRemainderTitlesForQA == expected.remainders.map(\.title) else {
            throw fail("\(label): default remainder parent/count/title accounting disagreed (live parents \(actualRemainderIDs), titles \(probe.inbox.fanoutRemainderTitlesForQA); expected parents \(expectedRemainderIDs), titles \(expected.remainders.map(\.title))")
        }
        for expectedRemainder in expected.remainders {
            guard let actual = probe.inbox.fanoutRemaindersByParentForQA[expectedRemainder.parentID],
                  actual.hiddenChildIDs == expectedRemainder.hiddenChildIDs,
                  actual.hiddenDescendantIDs == expectedRemainder.hiddenDescendantIDs,
                  actual.hiddenChildCount == expectedRemainder.hiddenChildIDs.count,
                  actual.title == expectedRemainder.title else {
                throw fail("\(label): live remainder for \(expectedRemainder.parentID.uuidString) did not preserve its exact hidden-child count/title")
            }
        }

        let expectedTableRows = expectedAgentCells + actualRemainders.count + expectedNonAgentRows
        guard probe.inbox.tableRowCountForQA == expectedTableRows,
              probe.inbox.nonAgentTableRowCountForQA == actualRemainders.count + expectedNonAgentRows else {
            throw fail("\(label): default table rows \(probe.inbox.tableRowCountForQA) != \(expectedAgentCells) capped agent cells + \(actualRemainders.count) exact remainder rows + \(expectedNonAgentRows) shelf/paging rows")
        }
    }

    /// Exercise the nested case in the live AppKit table. The root has nine
    /// direct children, its final visible child has nine grandchildren, and both
    /// caps therefore place a remainder after the same final grandchild. Folding
    /// that child removes the shared anchor: the root remainder must re-anchor to
    /// the folded child, expand the root, and leave the child's own remainder ready
    /// when the child is opened again.
    private static func checkNestedFanoutProbe(
        width: CGFloat, appearanceName: NSAppearance.Name
    ) throws {
        let epoch = Date(timeIntervalSinceReferenceDate: 810_000_000)
        func id(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "5B000000-0000-4000-8000-%012X", value))!
        }
        let rootID = id(200)
        let directIDs = (0..<9).map { id(210 + $0) }
        let grandchildIDs = (0..<9).map { id(230 + $0) }
        let root = AgentInboxRow(
            id: rootID, title: "Nested fan-out root", state: .ready,
            createdAt: epoch.addingTimeInterval(2_000))
        let direct = directIDs.enumerated().map { index, childID in
            AgentInboxRow(
                id: childID, title: "Nested child \(index)", state: .ready,
                lastActiveAt: epoch.addingTimeInterval(Double(900 - index)),
                depth: 1, createdAt: epoch.addingTimeInterval(Double(1_900 - index)),
                parentId: rootID)
        }
        let grandchildren = grandchildIDs.enumerated().map { index, childID in
            AgentInboxRow(
                id: childID, title: "Nested grandchild \(index)", state: .ready,
                lastActiveAt: epoch.addingTimeInterval(Double(800 - index)),
                depth: 2, createdAt: epoch.addingTimeInterval(Double(1_800 - index)),
                parentId: directIDs[7])
        }
        let rows = [root] + direct + grandchildren
        let sorted = InboxSort.sortForInbox(rows: rows)
        let bounded = InboxSort.boundedForInbox(rows: sorted)
        guard bounded.remainders.count == 2,
              bounded.rows.last?.id == bounded.remainders[0].afterRowID,
              bounded.remainders[0].afterRowID == bounded.remainders[1].afterRowID else {
            throw fail("sidebar-ux-check.nested-fanout@\(Int(width))pt.\(appearanceName.rawValue): model did not produce two same-anchor nested remainders")
        }
        let sharedAnchor = bounded.remainders[0].afterRowID
        guard bounded.remaindersByAfterRow[sharedAnchor]?.map(\.parentId)
                == [directIDs[7], rootID] else {
            throw fail("sidebar-ux-check.nested-fanout@\(Int(width))pt.\(appearanceName.rawValue): model lost child-before-parent remainder structure")
        }

        let height = CGFloat(
            (Double(rows.count + 2) * (AgentInboxView.rowHeight + Space.s)
                + AgentInboxView.scopeControlHeight + 160).rounded(.up))
        let probe = try makeSidebarProbeHost(
            width: width, height: height, appearanceName: appearanceName)
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.reload(rows: rows)
        probe.inbox.layoutForQA()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.layoutForQA()

        guard probe.inbox.rowIdsForQA == bounded.rows.map(\.id),
              probe.inbox.qaMaterializedRowCellCount == bounded.rows.count,
              probe.inbox.tableRowCountForQA == bounded.rows.count + 2,
              probe.inbox.nonAgentTableRowCountForQA == 2 else {
            throw fail("sidebar-ux-check.nested-fanout@\(Int(width))pt.\(appearanceName.rawValue): default table lost an agent or one of the two same-anchor remainder rows")
        }
        let initialRemainders = probe.inbox.fanoutRemainderRowsForQA
        guard initialRemainders.map(\.parentId) == [directIDs[7], rootID],
              initialRemainders[0].hiddenChildIDs == [grandchildIDs[8]],
              initialRemainders[1].hiddenChildIDs == [directIDs[8]],
              probe.inbox.fanoutRemainderTitlesForQA == ["1 more", "1 more"] else {
            throw fail("sidebar-ux-check.nested-fanout@\(Int(width))pt.\(appearanceName.rawValue): live remainder rows had the wrong parent, count or title")
        }

        guard probe.inbox.clickDisclosureForQA(id: directIDs[7]) else {
            throw fail("sidebar-ux-check.nested-fanout@\(Int(width))pt.\(appearanceName.rawValue): nested capped child disclosure was not materialized")
        }
        probe.inbox.layoutForQA()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.layoutForQA()
        let collapsedDefaultRows = InboxSort.visibleRows(
            bounded.rows, collapsed: [directIDs[7]])
        guard probe.inbox.collapsedParentsForQA.contains(directIDs[7]),
              probe.inbox.rowIdsForQA == collapsedDefaultRows.map(\.id),
              probe.inbox.fanoutRemainderRowsForQA.map(\.parentId) == [rootID],
              probe.inbox.fanoutRemainderRowsForQA.first?.hiddenChildIDs == [directIDs[8]],
              probe.inbox.tableRowCountForQA == collapsedDefaultRows.count + 1,
              probe.inbox.nonAgentTableRowCountForQA == 1 else {
            throw fail("sidebar-ux-check.nested-fanout@\(Int(width))pt.\(appearanceName.rawValue): folding the nested child lost or retargeted the root remainder")
        }

        guard probe.inbox.clickFanoutRemainderForQA(parentId: rootID) else {
            throw fail("sidebar-ux-check.nested-fanout@\(Int(width))pt.\(appearanceName.rawValue): root remainder was not clickable after its shared anchor folded")
        }
        probe.inbox.layoutForQA()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.layoutForQA()
        let rootExpanded = InboxSort.boundedForInbox(
            rows: sorted, expandedParents: [rootID])
        let collapsedRootExpandedRows = InboxSort.visibleRows(
            rootExpanded.rows, collapsed: [directIDs[7]])
        guard probe.inbox.expandedFanoutParentsForQA == Set([rootID]),
              probe.inbox.rowIdsForQA == collapsedRootExpandedRows.map(\.id),
              probe.inbox.rowIdsForQA.contains(directIDs[8]),
              probe.inbox.fanoutRemainderRowsForQA.isEmpty,
              probe.inbox.tableRowCountForQA == collapsedRootExpandedRows.count,
              probe.inbox.nonAgentTableRowCountForQA == 0 else {
            throw fail("sidebar-ux-check.nested-fanout@\(Int(width))pt.\(appearanceName.rawValue): re-anchored root expansion did not materialize its ninth child while preserving the nested fold")
        }

        guard probe.inbox.clickDisclosureForQA(id: directIDs[7]) else {
            throw fail("sidebar-ux-check.nested-fanout@\(Int(width))pt.\(appearanceName.rawValue): nested child could not be reopened after root expansion")
        }
        probe.inbox.layoutForQA()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.layoutForQA()
        guard !probe.inbox.collapsedParentsForQA.contains(directIDs[7]),
              probe.inbox.rowIdsForQA == rootExpanded.rows.map(\.id),
              probe.inbox.fanoutRemainderRowsForQA.map(\.parentId) == [directIDs[7]],
              probe.inbox.fanoutRemainderRowsForQA.first?.hiddenChildIDs == [grandchildIDs[8]],
              probe.inbox.tableRowCountForQA == rootExpanded.rows.count + 1 else {
            throw fail("sidebar-ux-check.nested-fanout@\(Int(width))pt.\(appearanceName.rawValue): reopening the nested child did not restore its own remainder")
        }

        guard probe.inbox.clickFanoutRemainderForQA(parentId: directIDs[7]) else {
            throw fail("sidebar-ux-check.nested-fanout@\(Int(width))pt.\(appearanceName.rawValue): child remainder button was not materialized after reopening")
        }
        probe.inbox.layoutForQA()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.layoutForQA()
        let bothExpanded = InboxSort.boundedForInbox(
            rows: sorted, expandedParents: [rootID, directIDs[7]])
        guard probe.inbox.expandedFanoutParentsForQA == Set([rootID, directIDs[7]]),
              probe.inbox.fanoutRemainderRowsForQA.isEmpty,
              probe.inbox.fanoutRemainderParentIDsForQA.isEmpty,
              probe.inbox.rowIdsForQA == sorted.map(\.id),
              probe.inbox.qaMaterializedRowCellCount == rows.count,
              probe.inbox.tableRowCountForQA == bothExpanded.rows.count,
              Set(probe.inbox.rowIdsForQA) == Set(rows.map(\.id)) else {
            throw fail("sidebar-ux-check.nested-fanout@\(Int(width))pt.\(appearanceName.rawValue): expanding both levels lost, duplicated or mis-targeted an agent")
        }
    }

    private static func checkSidebarProbe(
        _ probe: SidebarProbeHost, rows: [AgentInboxRow], width: CGFloat,
        appearanceName: NSAppearance.Name
    ) throws -> (cells: Int, labels: Int, truncated: Int, tiers: Set<RowFitTier>, slimTiers: Set<SlimRowFitTier>) {
        let label = "sidebar-ux-check@\(Int(width))pt.\(appearanceName.rawValue)"
        let theme: TokenTheme = appearanceName == .darkAqua ? .dark : .light
        // Size the whole subtree first. Applying rows before this line is the
        // offscreen-materialization bug this leg exists to prevent.
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.reload(rows: rows)
        probe.inbox.layoutForQA()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.layoutForQA()

        guard InboxSort.maxVisibleChildren == 8 else {
            throw fail("\(label): the bounded inline policy changed from the independently gated eight-child cap")
        }
        let sortedRows = InboxSort.sortForInbox(rows: rows)
        let expectedDefault = try independentlyExpectedDefaultFanout(rows)
        guard expectedDefault.visibleIDs.count < rows.count else {
            throw fail("\(label): the defect corpus did not exercise a capped parent")
        }
        try assertDefaultFanoutAccounting(
            probe, rows: rows, expected: expectedDefault, label: label)
        guard let fanoutParent = expectedDefault.remainders.first?.parentID,
              let defaultRemainder = probe.inbox.fanoutRemaindersByParentForQA[fanoutParent] else {
            throw fail("\(label): the capped parent did not render an explicit remainder")
        }
        guard Set(defaultRemainder.hiddenDescendantIDs).intersection(Set(expectedDefault.visibleIDs)).isEmpty,
              Set(defaultRemainder.hiddenDescendantIDs).union(Set(expectedDefault.visibleIDs)) == Set(rows.map(\.id)) else {
            throw fail("\(label): the remainder did not account for every hidden child without losing a visible id")
        }

        // The nested witness uses a separate live host so the forty-child defect
        // corpus remains unchanged. It intentionally ends one visible capped child
        // at the same anchor as its parent's remainder and presses both real
        // affordances through their target/action path.
        try checkNestedFanoutProbe(width: width, appearanceName: appearanceName)

        // A blocked child is deliberately kept in the hidden ninth slot: the
        // first eight siblings are given the same higher-priority human-blocked
        // state, so this witness proves propagation from a CAPPED child rather
        // than from a child that happened to become visible.
        let directChildren = rows.filter { $0.parentId == fanoutParent }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
        guard directChildren.count > InboxSort.maxVisibleChildren else {
            throw fail("\(label): fan-out attention witness has no hidden ninth child")
        }
        let blockedIDs = Set(directChildren.prefix(InboxSort.maxVisibleChildren + 1).map(\.id))
        let blockedRows = rows.map { row -> AgentInboxRow in
            guard blockedIDs.contains(row.id) else { return row }
            return AgentInboxRow(
                id: row.id, title: row.title, projectName: row.projectName,
                workspaceName: row.workspaceName, state: .input, attention: row.attention,
                lifecycle: row.lifecycle, model: row.model, role: row.role, branch: row.branch,
                isIsolated: row.isIsolated, elapsed: row.elapsed, lastActiveAt: row.lastActiveAt,
                depth: row.depth, variant: row.variant, createdAt: row.createdAt,
                parentId: row.parentId, isUnconfirmed: row.isUnconfirmed,
                settlementBlocked: row.settlementBlocked)
        }
        guard let blockedParent = blockedRows.first(where: { $0.id == fanoutParent }),
              blockedParent.attention == rows.first(where: { $0.id == fanoutParent })?.attention else {
            throw fail("\(label): the capped-child witness changed the parent's own attention watermark")
        }
        probe.inbox.reload(rows: blockedRows)
        probe.inbox.layoutForQA()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.layoutForQA()
        guard let blockedParentGeometry = probe.inbox.qaRowGeometriesForQA.first(where: { $0.agentID == fanoutParent }),
              blockedParentGeometry.labels.first(where: { $0.element == "meta" })?.text.contains("needs you") == true,
              probe.inbox.fanoutRemainderAccessibilityLabelsForQA.contains(where: { $0.contains("needs you") }) else {
            throw fail("\(label): a blocked child hidden behind the remainder did not raise the parent rollup")
        }
        // Restore the corpus before the all-ids expansion witness. The real
        // remainder button, not a direct Set mutation, is the expansion path.
        probe.inbox.reload(rows: rows)
        probe.inbox.layoutForQA()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.layoutForQA()
        guard probe.inbox.clickFanoutRemainderForQA(parentId: fanoutParent) else {
            throw fail("\(label): the live N more affordance did not expand its parent")
        }
        probe.inbox.layoutForQA()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.layoutForQA()
        let expandedIDs = probe.inbox.rowIdsForQA
        guard expandedIDs == sortedRows.map(\.id),
              probe.inbox.qaMaterializedRowCellCount == rows.count,
              probe.inbox.fanoutRemainderParentIDsForQA.isEmpty,
              probe.inbox.expandedFanoutParentsForQA.contains(fanoutParent) else {
            throw fail("\(label): expanded fan-out did not materialize every corpus agent id")
        }

        let cells = probe.inbox.qaMaterializedRowCells
        guard !cells.isEmpty else {
            throw fail("\(label): no row cells materialized")
        }
        guard cells.count == rows.count,
              probe.inbox.qaMaterializedRowCellCount == rows.count else {
            throw fail("\(label): expanded materialized \(cells.count) row cells for \(rows.count) corpus rows")
        }
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
        var observedSlimTiers = Set<SlimRowFitTier>()
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
                expectedElements = ["cell", "card", "project", "title", "state", "elapsed", "meta", "branch", "provider"]
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
                ? ["project", "title", "state", "elapsed", "meta", "branch", "provider"]
                : ["glyph", "title", "branch", "time"]
            guard Set(geometry.labels.map(\.element)) == expectedLabels else {
                throw fail("\(label): '\(row.title)' did not expose every live label")
            }
            let measurementsByElement = Dictionary(uniqueKeysWithValues: geometry.labels.map { ($0.element, $0) })
            guard let renderedTitle = measurementsByElement["title"] else {
                throw fail("\(label): '\(row.title)' has no live name label")
            }
            let visibleStrings = geometry.labels
                .filter { !$0.isHidden && !$0.text.isEmpty }
                .map(\.text)
            let duplicateStrings = Dictionary(grouping: visibleStrings, by: { $0 })
                .filter { $0.value.count > 1 }
                .map(\.key)
            guard duplicateStrings.isEmpty else {
                throw fail("\(label): '\(row.title)' draws the same string twice: \(duplicateStrings.sorted().joined(separator: ", "))")
            }
            guard renderedTitle.text == row.displayTitle,
                  !renderedTitle.text.isEmpty else {
                throw fail("\(label): '\(row.title)' does not resolve to a human-facing name in the name position")
            }
            if row.titleIsModelIdentifier {
                guard renderedTitle.text == AgentInboxRow.untitled,
                      renderedTitle.text != row.model else {
                    throw fail("\(label): model id '\(row.model ?? "")' occupies the name position for '\(row.title)'")
                }
            }
            if row.variant == .card {
                let provider = measurementsByElement["provider"]
                if let model = row.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                    guard let provider, !provider.isHidden, provider.text == AgentProviderGlyph.glyph(for: model),
                          provider.text != model,
                          provider.accessibilityLabel == model,
                          provider.toolTip == model else {
                        throw fail("\(label): '\(row.title)' provider glyph lost the full model '\(model)' to VoiceOver/help or painted the model as prose")
                    }
                } else {
                    guard provider?.isHidden == true else {
                        throw fail("\(label): '\(row.title)' reserves a provider slot without a model")
                    }
                }

                // P2.4's absence rule is about the live layout, not only the
                // string value: an empty branch/meta/provider label must be
                // hidden and take no horizontal room in the arranged detail band.
                let detailSlots: [(String, Bool)] = [
                    ("branch", row.branch?.isEmpty == false),
                    ("meta", measurementsByElement["meta"]?.text.isEmpty == false),
                    ("provider", row.model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false),
                ]
                for (element, shouldDraw) in detailSlots {
                    guard let measurement = measurementsByElement[element],
                          measurement.isHidden == !shouldDraw else {
                        throw fail("\(label): '\(row.title)' has inconsistent \(element) presence between its row facts and the live tree")
                    }
                    if !shouldDraw {
                        guard measurement.drawableWidth <= 0.5 else {
                            throw fail("\(label): '\(row.title)' hides empty \(element) content but still reserves \(measurement.drawableWidth)pt of alignment width")
                        }
                    }
                }
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
                      measurement.isHidden || abs(measurement.drawableWidth - Double(measurement.frame.width)) <= 0.01 else {
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
            } else {
                // Parenthood from the rows array, not the cell: the oracle must
                // be able to catch a cell that hid its own triangle.
                let hasChildren = rows.contains { $0.parentId == row.id }
                try expectSlimRowFitTier(geometry, row: row, hasChildren: hasChildren, label: label)
                if let slimTier = geometry.slimFitTier { observedSlimTiers.insert(slimTier) }
            }
        }
        guard paintedStates == Set(InboxState.allCases) else {
            throw fail("\(label): paint seam covered \(paintedStates.count) states, expected every InboxState")
        }
        // P1.3, over the whole subtree at this width and appearance.
        try expectHairlineContainment(probe.inbox, label: label)
        return (cells.count, labelCount, truncatedCount, observedTiers, observedSlimTiers)
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
    private static let sidebarDetailBandElements = ["branch", "meta", "provider"]

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
        guard spoken.contains(row.displayTitle) else {
            throw fail("\(label): the cell for '\(row.displayTitle)' does not say its own name to VoiceOver")
        }
        if let model = row.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            if byElement["provider"]?.isHidden == true {
                guard spoken.contains(model) else {
                    throw fail("\(label): the hidden provider fact for '\(row.displayTitle)' was not relocated to the row owner")
                }
            } else {
                guard byElement["provider"]?.accessibilityLabel == model else {
                    throw fail("\(label): the visible provider glyph for '\(row.displayTitle)' does not own its full model in VoiceOver")
                }
            }
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

    /// The slim variant's measured ladder, read from the same live labels as the
    /// card gate. Branch and relative time may disappear, but the name is kept
    /// whenever the glyph-plus-name line itself fits; hidden facts stay in the
    /// cell's accessibility label.
    private static func expectSlimRowFitTier(
        _ geometry: AgentInboxRowGeometryForQA, row: AgentInboxRow, hasChildren: Bool,
        label: String
    ) throws {
        guard let tier = geometry.slimFitTier else {
            throw fail("\(label): '\(row.title)' is slim but resolved no measured slim tier")
        }
        var byElement: [String: AgentInboxLabelGeometryForQA] = [:]
        for measurement in geometry.labels { byElement[measurement.element] = measurement }
        guard let card = geometry.elementFrames["card"],
              let glyph = byElement["glyph"],
              let title = byElement["title"],
              let branch = byElement["branch"],
              let time = byElement["time"] else {
            throw fail("\(label): '\(row.title)' slim geometry lost a glyph, name, branch or time label")
        }
        let available = Double(card.width) - Inset.row.horizontal

        // The fold triangle. `hasChildren` comes from the ROWS ARRAY, never from
        // the cell — a parked parent that hid its triangle to make the tier math
        // work must fail here, and a cell-reported flag could not catch that.
        // The independent need is a fresh InboxDisclosureButton measured outside
        // the cell's layout, the same move as measuring the time lane from the
        // formatter's own forms instead of the cell's constant.
        let disclosureFrame = geometry.elementFrames["disclosure"]
        if hasChildren {
            guard let disclosureFrame, disclosureFrame.width > 0 else {
                throw fail("\(label): '\(row.title)' is a parent, but its slim cell draws no fold triangle — a parent must never hide its disclosure to make room")
            }
        } else if disclosureFrame != nil {
            throw fail("\(label): '\(row.title)' has no children but its slim cell draws a fold triangle")
        }
        let disclosureNeed: Double
        if hasChildren {
            let probeButton = InboxDisclosureButton()
            probeButton.show(.expanded)
            let expandedNeed = Double(probeButton.fittingSize.width)
            probeButton.show(.collapsed)
            let collapsedNeed = Double(probeButton.fittingSize.width)
            disclosureNeed = max(expandedNeed, collapsedNeed)
            if let disclosureFrame {
                guard Double(disclosureFrame.width) + 0.5 >= min(expandedNeed, collapsedNeed) else {
                    throw fail(String(
                        format: "%@: '%@' slim disclosure lane is %.1fpt, below its measured %.1fpt need",
                        label, row.title, Double(disclosureFrame.width), min(expandedNeed, collapsedNeed)))
                }
            }
        } else {
            disclosureNeed = 0
        }

        // Resolve the expected tier independently from the live text needs. This
        // is deliberately not `AgentInboxSlimCellView.fitTier(...)`: a slim cell
        // that drops the branch too early must disagree with this arithmetic, or
        // the check would only prove that production agrees with itself. Measure
        // each exact live string with its live font and include the 4pt NSTextField
        // cell inset, just as the card ladder and drawable-width gate do.
        func exactNeed(
            _ measurement: AgentInboxLabelGeometryForQA, included: Bool
        ) throws -> Double {
            guard included else { return 0 }
            guard let font = measurement.font else {
                throw fail("\(label): '\(row.title)' slim \(measurement.element) label has no font for independent tier measurement")
            }
            return Double(ceil((measurement.text as NSString).size(withAttributes: [.font: font]).width))
                + Metrics.cellTextInset
        }
        let hasBranch = row.branch?.isEmpty == false
        let relative = AgentInboxSlimCellView.relativeText(
            for: row.lifecycle, now: LabFixtures.inboxNow)
        let hasRelativeTime = !relative.isEmpty
        if hasBranch {
            guard !branch.text.isEmpty else {
                throw fail("\(label): '\(row.title)' has a branch fact but the live slim branch string is empty")
            }
        }
        if hasRelativeTime {
            guard time.text == relative else {
                throw fail("\(label): '\(row.title)' live slim time '\(time.text)' disagrees with its measured relative time '\(relative)'")
            }
        }
        let glyphNeed = try exactNeed(glyph, included: true)
        let titleNeed = try exactNeed(title, included: true)
        let branchNeed = try exactNeed(branch, included: hasBranch)
        let timeTextNeed = try exactNeed(time, included: hasRelativeTime)
        // The live time is exact above, but the layout deliberately reserves a
        // stable lane for every bounded formatter form so a clock tick cannot
        // retake the name's points. Re-measure that lane here rather than reading
        // the slim cell's production constant; the exact live string remains part
        // of the need via `max`.
        let measuredTimeLaneNeed = AgentElapsedFormatter.columnLabels
            .flatMap { row.isUnconfirmed ? ["last seen \($0)"] : ["\($0) ago", "in \($0)"] }
            .map { candidate in
                Double(ceil((candidate as NSString).size(withAttributes: [.font: NSFont.token(.captionMono)]).width))
                    + Metrics.cellTextInset
            }
            .max() ?? Metrics.cellTextInset
        let timeNeed = hasRelativeTime ? max(timeTextNeed, measuredTimeLaneNeed) : 0
        func totalNeed(drawsBranch: Bool, drawsTime: Bool) -> Double {
            // The disclosure participates exactly as production's
            // `SlimRowFitNeeds.total` says it does: a positive width in the
            // stack, paying its own `Space.m` gap. Omitting it here was round
            // 2's blocking finding — the oracle agreed with production only
            // because no checked slim fixture was a parent.
            let widths = [glyphNeed, titleNeed,
                          drawsBranch ? branchNeed : 0,
                          drawsTime ? timeNeed : 0,
                          disclosureNeed]
                .filter { $0 > 0 }
            return widths.reduce(0, +) + Space.m * Double(max(0, widths.count - 1))
        }
        let expected: SlimRowFitTier
        if totalNeed(drawsBranch: true, drawsTime: true) <= available {
            expected = .full
        } else if hasBranch && totalNeed(drawsBranch: false, drawsTime: true) <= available {
            expected = .branchHidden
        } else {
            expected = .timeHidden
        }
        guard tier == expected else {
            throw fail(String(
                format: "%@: '%@' resolved slim %@ with %.1fpt available, but measured need resolves %@",
                label, row.title, tier.rawValue, available, expected.rawValue))
        }
        let shouldDrawBranch = hasBranch && tier.drawsBranch
        let shouldDrawTime = hasRelativeTime && tier.drawsTime
        guard branch.isHidden == !shouldDrawBranch,
              time.isHidden == !shouldDrawTime else {
            throw fail("\(label): '\(row.title)' slim tier \(tier.rawValue) disagrees with live branch/time visibility")
        }
        if branch.isHidden, let branchValue = row.branch {
            let branchText = AgentInboxSlimCellView.branchText(branch: branchValue)
            if !branchText.isEmpty {
                guard geometry.accessibilityLabel?.contains(branchText) == true else {
                    throw fail("\(label): '\(row.title)' dropped its branch without relocating '\(branchText)' to VoiceOver")
                }
            }
        }
        if time.isHidden, hasRelativeTime {
            guard geometry.accessibilityLabel?.contains(relative) == true else {
                throw fail("\(label): '\(row.title)' dropped its relative time without relocating '\(relative)' to VoiceOver")
            }
        }
        let baseNeed = glyphNeed + titleNeed + Space.m
        if baseNeed <= available + 0.01 {
            guard title.drawableWidth + 0.5 >= titleNeed else {
                throw fail(String(
                    format: "%@: slim name '%@' elides with %.1fpt of glyph-plus-name room and %.1fpt needed — optional facts must yield before the name",
                    label, title.text, available, titleNeed))
            }
        } else if title.drawableWidth + 0.5 < titleNeed {
            guard tier == .timeHidden else {
                throw fail("\(label): slim name '\(row.title)' elides before the branch/time sacrifices are exhausted")
            }
        }
        guard branch.compressionResistance < title.compressionResistance,
              title.compressionResistance == Double(AgentInboxCellView.nameCompressionResistance.rawValue),
              glyph.compressionResistance == Double(NSLayoutConstraint.Priority.required.rawValue),
              time.compressionResistance == Double(NSLayoutConstraint.Priority.required.rawValue) else {
            throw fail("\(label): slim '\(row.title)' does not expose branch < name < required glyph/time compression resistance")
        }
        if !time.isHidden {
            guard Double(time.frame.width) + 0.5 >= AgentInboxSlimCellView.relativeTimeColumnWidth else {
                throw fail("\(label): slim '\(row.title)' time lane is \(time.frame.width)pt, below its measured \(AgentInboxSlimCellView.relativeTimeColumnWidth)pt column")
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
            // Keep the old three-digit-hour fixture's duration, but measure the
            // bounded vocabulary it now emits (`6d`) rather than a second legacy
            // elapsed string.
            elapsed: AgentInboxCellView.measuredTextWidth(
                AgentElapsedFormatter.elapsedLabel(162 * 3_600 + 21 * 60), .captionMono),
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

    // MARK: - P2.3 — content-derived card height
    //
    // The card has three possible content bands: metadata, the name, and detail.
    // This probe uses deliberately small rows rather than the baseline corpus so
    // every one-line, two-line, and three-line case is visible at every shipping
    // width. It reads the laid-out table and the visible label frames, not the
    // height function under test.
    private static func checkSidebarContentDerivedHeights() throws -> Int {
        let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let rows = [
            AgentInboxRow(
                id: UUID(uuidString: "5A000000-0000-4000-8000-000000000001")!,
                title: "One line", state: .ready, attention: .none,
                // Empty strings are accepted by the public row initializer. They
                // must be treated like absent detail, or the cell would draw a
                // separator-only `" · "` band that the height derivation omits.
                model: "", role: "", branch: nil, elapsed: nil,
                variant: .card, createdAt: epoch),
            AgentInboxRow(
                id: UUID(uuidString: "5A000000-0000-4000-8000-000000000002")!,
                title: "Two lines", projectName: "continuum", state: .ready,
                attention: .none, model: nil, role: nil, branch: nil, elapsed: nil,
                variant: .card, createdAt: epoch.addingTimeInterval(1)),
            AgentInboxRow(
                id: UUID(uuidString: "5A000000-0000-4000-8000-000000000003")!,
                title: "Three lines", projectName: "continuum", state: .ready,
                attention: .none, model: nil, role: "builder", branch: nil, elapsed: nil,
                variant: .card, createdAt: epoch.addingTimeInterval(2)),
        ]
        let captionHiddenProject = AgentInboxRow(
            id: UUID(uuidString: "5A000000-0000-4000-8000-000000000004")!,
            title: "Caption hidden", projectName: String(repeating: "project-name-", count: 32),
            state: .ready, attention: .none,
            model: nil, role: nil, branch: nil, elapsed: nil,
            variant: .card, createdAt: epoch.addingTimeInterval(3))
        let widths: [CGFloat] = [
            CGFloat(WorkspaceSidebarConfig.minWidth),
            CGFloat(WorkspaceSidebarConfig.defaultWidth),
            320,
        ]
        guard let resizingProject = (1...128).map({ count in
            String(repeating: "project-", count: count)
        }).first(where: { project in
            let candidate = AgentInboxRow(
                id: UUID(uuidString: "5A000000-0000-4000-8000-000000000005")!,
                title: "Resize witness", projectName: project, state: .ready,
                attention: .none, model: nil, role: nil, branch: nil, elapsed: nil,
                variant: .card, createdAt: epoch.addingTimeInterval(4))
            return AgentInboxCellView.fitTier(
                for: candidate, available: 320 - Inset.card.horizontal, disclosure: .none) == .full
                && AgentInboxCellView.fitTier(
                    for: candidate, available: CGFloat(WorkspaceSidebarConfig.minWidth) - Inset.card.horizontal,
                    disclosure: .none) == .captionHidden
        }) else {
            throw fail("sidebar-ux-check.content-height: could not create a project that changes fit tier between 220pt and 320pt")
        }
        let resizingRow = AgentInboxRow(
            id: UUID(uuidString: "5A000000-0000-4000-8000-000000000005")!,
            title: "Resize witness", projectName: resizingProject, state: .ready,
            attention: .none, model: nil, role: nil, branch: nil, elapsed: nil,
            variant: .card, createdAt: epoch.addingTimeInterval(4))
        let maxHeight = CGFloat(
            (Double(rows.count + 1) * AgentInboxView.rowHeight
                + AgentInboxView.scopeControlHeight + 160).rounded(.up)
        )
        var asserted = 0
        var measuredHeights: Set<String> = []

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for width in widths {
                let probe = try makeSidebarProbeHost(
                    width: width, height: maxHeight, appearanceName: appearanceName)
                // The host is sized before content is applied. `layoutForQA` then
                // forces the list's own materialization/layout pass, so this leg
                // cannot pass by inspecting only three row values.
                probe.inbox.reload(rows: rows)
                probe.inbox.layoutForQA()
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.layoutForQA()

                let sortedRows = InboxSort.sortForInbox(rows: rows)
                let geometries = Dictionary(
                    uniqueKeysWithValues: probe.inbox.qaRowGeometriesForQA.compactMap { geometry in
                        geometry.agentID.map { ($0, geometry) }
                    })
                guard probe.inbox.rowHeightsForQA.count == sortedRows.count,
                      geometries.count == sortedRows.count else {
                    throw fail("sidebar-ux-check.content-height@\(Int(width))pt.\(appearanceName.rawValue): materialized rows do not cover the one/two/three-line fixtures")
                }

                for (index, row) in sortedRows.enumerated() {
                    guard let geometry = geometries[row.id],
                          probe.inbox.rowHeightsForQA.indices.contains(index) else {
                        throw fail("sidebar-ux-check.content-height@\(Int(width))pt.\(appearanceName.rawValue): missing live geometry for \(row.title)")
                    }
                    if row.id == rows[0].id {
                        guard AgentInboxCellView.metaText(
                            isIsolated: row.isIsolated,
                            hasBranch: row.branch?.isEmpty == false
                        ).isEmpty,
                              geometry.labels.first(where: { $0.element == "meta" })?.isHidden == true else {
                            throw fail("sidebar-ux-check.content-height@\(Int(width))pt.\(appearanceName.rawValue): empty isolation/remote facts produced a visible separator-only detail band")
                        }
                    }
                    let roles: [TextRole] = (row.drawsMetaLine ? [.label] : [])
                        + [.title]
                        + (row.drawsDetailLine ? [.label] : [])
                    let expected = Metrics.rowHeight(for: roles, insets: Inset.card, spacing: Space.s)
                    let measured = probe.inbox.rowHeightsForQA[index]
                    guard abs(measured - expected) <= 0.5 else {
                        throw fail(String(
                            format: "sidebar-ux-check.content-height@%.0fpt.%@: '%@' drew %d content lines at %.1fpt, expected %.1fpt from Metrics",
                            width, appearanceName.rawValue, row.title, row.drawnLineCount, measured, expected))
                    }
                    measuredHeights.insert("\(row.drawnLineCount)=\(String(format: "%.1f", measured))")

                    let visibleFrames = geometry.labels
                        .filter { !$0.isHidden && !$0.text.isEmpty && $0.frame.height > 0 }
                        .map(\.frame)
                    guard let minY = visibleFrames.map(\.minY).min(),
                          let maxY = visibleFrames.map(\.maxY).max(),
                          let cardFrame = geometry.elementFrames["card"] else {
                        throw fail("sidebar-ux-check.content-height@\(Int(width))pt.\(appearanceName.rawValue): '\(row.title)' has no visible drawn content frame")
                    }
                    let drawnHeight = Double(maxY - minY)
                    let interiorHeight = Double(cardFrame.height) - Inset.card.vertical
                    let slack = interiorHeight - drawnHeight
                    guard slack >= -0.5, slack <= 4.0 else {
                        throw fail(String(
                            format: "sidebar-ux-check.content-height@%.0fpt.%@: '%@' leaves %.1fpt unexplained vertical slack (card %.1fpt, drawn %.1fpt, inset %.1fpt)",
                            width, appearanceName.rawValue, row.title, slack,
                            cardFrame.height, drawnHeight, Inset.card.vertical))
                    }
                    asserted += 1
                }

                // A caption-hidden project is the only content in this fixture's
                // metadata band. Once the measured-fit tier drops that project,
                // the band itself must collapse; otherwise the row keeps a 14pt
                // shelf with no drawable content and the height proof is lying.
                // Negative witness observed on the final check: forcing the height
                // path to keep the project produced red at the exact message
                // `caption-hidden sole-meta row reserved 61.0pt, wanted 43.0pt`;
                // the source was restored and its SHA-256 verified before green.
                let hiddenProbe = try makeSidebarProbeHost(
                    width: width, height: maxHeight, appearanceName: appearanceName)
                hiddenProbe.inbox.reload(rows: [captionHiddenProject])
                hiddenProbe.inbox.layoutForQA()
                hiddenProbe.host.layoutSubtreeIfNeeded()
                hiddenProbe.inbox.layoutForQA()
                guard let hiddenGeometry = hiddenProbe.inbox.qaRowGeometriesForQA.first,
                      hiddenGeometry.agentID == captionHiddenProject.id else {
                    throw fail("sidebar-ux-check.content-height@\(Int(width))pt.\(appearanceName.rawValue): caption-hidden witness did not materialize")
                }
                guard hiddenGeometry.fitTier == .captionHidden else {
                    throw fail("sidebar-ux-check.content-height@\(Int(width))pt.\(appearanceName.rawValue): over-wide sole project did not resolve captionHidden")
                }
                let hiddenProject = hiddenGeometry.labels.first { $0.element == "project" }
                guard hiddenProject?.isHidden == true else {
                    throw fail("sidebar-ux-check.content-height@\(Int(width))pt.\(appearanceName.rawValue): captionHidden left the sole project visible")
                }
                let oneLineHeight = Metrics.rowHeight(
                    for: [.title], insets: Inset.card, spacing: Space.s)
                guard let hiddenHeight = hiddenProbe.inbox.rowHeightForQA(id: captionHiddenProject.id),
                      abs(hiddenHeight - oneLineHeight) <= 0.5 else {
                    throw fail(String(
                        format: "sidebar-ux-check.content-height@%.0fpt.%@: caption-hidden sole-meta row reserved %.1fpt, wanted %.1fpt for its one drawn line",
                        width, appearanceName.rawValue, hiddenProbe.inbox.rowHeightForQA(id: captionHiddenProject.id) ?? -1, oneLineHeight))
                }
                let hiddenVisibleLabels = hiddenGeometry.labels.filter {
                    !$0.isHidden && !$0.text.isEmpty && $0.frame.height > 0
                }
                guard hiddenVisibleLabels.map(\.element) == ["title"] else {
                    throw fail("sidebar-ux-check.content-height@\(Int(width))pt.\(appearanceName.rawValue): caption-hidden witness still has a visible metadata label")
                }
                asserted += 3
            }

            // Exercise the live divider path, not only fresh hosts. The same row
            // must shed its sole project band at 220pt and restore it at 320pt;
            // `noteHeightOfRows` is the part that keeps AppKit's cache in step with
            // the cell's width-driven tier.
            let transitionRootProbe = try makeSidebarProbeHost(
                width: 320, height: maxHeight, appearanceName: appearanceName)
            // The window content view is device-pixel rounded by AppKit. Keep
            // that window root fixed and put this one resize witness in a
            // regular child host: its frame can express the original 0.5pt
            // divider move while the cells remain attached to the live window.
            let transitionHost = NSView(frame: transitionRootProbe.host.bounds)
            transitionHost.autoresizingMask = []
            let transitionInbox = transitionRootProbe.inbox
            let inboxConstraints = transitionRootProbe.host.constraints.filter { constraint in
                (constraint.firstItem as? NSView) === transitionInbox
                    || (constraint.secondItem as? NSView) === transitionInbox
            }
            transitionRootProbe.host.removeConstraints(inboxConstraints)
            transitionInbox.removeFromSuperview()
            transitionRootProbe.host.addSubview(transitionHost)
            transitionInbox.translatesAutoresizingMaskIntoConstraints = true
            transitionHost.addSubview(transitionInbox)
            transitionInbox.frame = transitionHost.bounds
            let transitionProbe = SidebarProbeHost(
                window: transitionRootProbe.window, host: transitionHost, inbox: transitionInbox)
            func layoutTransitionHost(width: CGFloat, setWindowContentSize: Bool = false) {
                if setWindowContentSize {
                    let requestedSize = NSSize(width: width, height: maxHeight)
                    // This branch is used by the P6.5 one-host remainder witness.
                    // Relax the probe window's previous exact-size clamp before
                    // setting each live width; otherwise AppKit would keep the
                    // first 320pt content size while the child host appeared to
                    // resize.
                    transitionProbe.window.contentMinSize = .zero
                    transitionProbe.window.contentMaxSize = requestedSize
                    transitionProbe.window.setContentSize(requestedSize)
                }
                var frame = transitionProbe.host.frame
                frame.size.width = width
                frame.size.height = maxHeight
                transitionProbe.host.frame = frame
                transitionProbe.inbox.frame = transitionProbe.host.bounds
                transitionProbe.host.layoutSubtreeIfNeeded()
                transitionProbe.inbox.layoutForQA()
                transitionProbe.inbox.setViewportWidthForQA(Double(width))
                transitionProbe.host.layoutSubtreeIfNeeded()
                transitionProbe.inbox.layoutForQA()
            }
            transitionProbe.inbox.reload(rows: [resizingRow])
            transitionProbe.inbox.layoutForQA()
            transitionProbe.host.layoutSubtreeIfNeeded()
            transitionProbe.inbox.layoutForQA()
            let transitionTwoLineHeight = Metrics.rowHeight(
                for: [.label, .title], insets: Inset.card, spacing: Space.s)
            let transitionOneLineHeight = Metrics.rowHeight(
                for: [.title], insets: Inset.card, spacing: Space.s)
            guard let wideGeometry = transitionProbe.inbox.qaRowGeometriesForQA.first,
                  wideGeometry.fitTier == .full,
                  wideGeometry.labels.first(where: { $0.element == "project" })?.isHidden == false,
                  let wideHeight = transitionProbe.inbox.rowHeightForQA(id: resizingRow.id),
                  abs(wideHeight - transitionTwoLineHeight) <= 0.5 else {
                throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): resize witness did not start as a full two-line row at 320pt")
            }
            func expectRenameEditorToFollowTitle(_ phase: String) throws {
                guard let editor = transitionProbe.inbox.renameFieldFrameForQA,
                      let title = transitionProbe.inbox.titleFrameForQA(id: resizingRow.id) else {
                    throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): rename editor lost its live title geometry during \(phase)")
                }
                let expected = title.insetBy(dx: -Space.xs, dy: -Space.xs)
                guard abs(editor.minX - expected.minX) <= 0.5,
                      abs(editor.minY - expected.minY) <= 0.5,
                      abs(editor.width - expected.width) <= 0.5,
                      abs(editor.height - expected.height) <= 0.5 else {
                    throw fail(String(
                        format: "sidebar-ux-check.content-height.%@: rename editor stayed at %.1f,%.1f %.1fx%.1f during %@; live title wants %.1f,%.1f %.1fx%.1f",
                        appearanceName.rawValue, editor.minX, editor.minY, editor.width, editor.height,
                        phase, expected.minX, expected.minY, expected.width, expected.height))
                }
            }
            guard transitionProbe.inbox.beginRename(agentId: resizingRow.id) else {
                throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): resize witness could not open its inline rename editor")
            }
            try expectRenameEditorToFollowTitle("the initial wide layout")
            let resizingNeeds = AgentInboxCellView.RowFitNeeds(
                project: AgentInboxCellView.measuredTextWidth(resizingRow.projectName ?? "", .caption),
                state: AgentInboxCellView.measuredTextWidth(resizingRow.label ?? "", .label),
                elapsed: AgentInboxCellView.measuredTextWidth(
                    AgentInboxCellView.elapsedText(resizingRow.elapsed) ?? "", .captionMono),
                title: AgentInboxCellView.measuredTextWidth(resizingRow.title, .title),
                disclosure: 0)
            // The height delegate and the live cell both use the actual table
            // column. The vertical scroller narrows that column inside the outer
            // sidebar, so include that measured lane difference in the boundary.
            let cellWidth = wideGeometry.elementFrames["cell"]?.width ?? 0
            let columnInset = max(0, Double(transitionProbe.inbox.bounds.width) - Double(cellWidth))
            let fractionalBoundary = resizingNeeds.metaBandNeed(
                elapsed: true, project: true) + Inset.card.horizontal + columnInset
            // The offscreen display is 1x, so AppKit snaps a fractional content
            // frame to its neighbouring device pixel. Straddle the measured
            // boundary with two fractional divider positions only 0.5pt apart;
            // the live cell widths below prove that the transition was real rather
            // than a large requested frame jump.
            let fractionalAbove = fractionalBoundary + 0.125
            let fractionalBelow = fractionalBoundary - 0.375
            guard fractionalBelow > Double(WorkspaceSidebarConfig.minWidth),
                  fractionalAbove < 320 else {
                throw fail(String(
                    format: "sidebar-ux-check.content-height.%@: resize witness has no fractional tier boundary inside the shipping widths (%.2fpt)",
                    appearanceName.rawValue, fractionalBoundary))
            }

            // The two widths straddle a measured tier boundary by a fractional
            // divider move. A point-sized invalidation tolerance would leave this
            // transition stale even though the drawn project band changes.
            layoutTransitionHost(width: CGFloat(fractionalAbove))
            let fractionalWideGeometry = transitionProbe.inbox.qaRowGeometriesForQA.first
            let fractionalWideColumnWidth = transitionProbe.inbox.columnWidthForQA
            let fractionalWideHeight = transitionProbe.inbox.rowHeightForQA(id: resizingRow.id)
            guard fractionalWideGeometry?.fitTier == .full,
                  let fractionalWideHeight,
                  abs(fractionalWideHeight - transitionTwoLineHeight) <= 0.5 else {
                throw fail(String(
                    format: "sidebar-ux-check.content-height.%@: fractional width %.2fpt lost its full two-line height (inbox %.3f, cell %.3f, tier %@, project hidden %@, height %.1f wanted %.1f)",
                    appearanceName.rawValue, fractionalAbove,
                    transitionProbe.inbox.bounds.width,
                    fractionalWideGeometry?.elementFrames["cell"]?.width ?? -1,
                    fractionalWideGeometry?.fitTier?.rawValue ?? "nil",
                    String(describing: fractionalWideGeometry?.labels.first(where: { $0.element == "project" })?.isHidden),
                    fractionalWideHeight ?? -1, transitionTwoLineHeight))
            }
            layoutTransitionHost(width: CGFloat(fractionalBelow))
            let fractionalNarrowGeometry = transitionProbe.inbox.qaRowGeometriesForQA.first
            let fractionalNarrowColumnWidth = transitionProbe.inbox.columnWidthForQA
            let fractionalNarrowHeight = transitionProbe.inbox.rowHeightForQA(id: resizingRow.id)
            guard abs(fractionalWideColumnWidth - fractionalNarrowColumnWidth) > 0,
                  abs(fractionalWideColumnWidth - fractionalNarrowColumnWidth) <= 0.5 else {
                throw fail(String(
                    format: "sidebar-ux-check.content-height.%@: fractional tier crossing requested %.3fpt, but the live column moved %.3fpt (above %.3f, below %.3f) — assert the actual divider delta, not the request",
                    appearanceName.rawValue, fractionalAbove - fractionalBelow,
                    abs(fractionalWideColumnWidth - fractionalNarrowColumnWidth),
                    fractionalWideColumnWidth,
                    fractionalNarrowColumnWidth))
            }
            guard fractionalNarrowGeometry?.fitTier == .captionHidden,
                  let fractionalNarrowHeight,
                  abs(fractionalNarrowHeight - transitionOneLineHeight) <= 0.5 else {
                throw fail(String(
                    format: "sidebar-ux-check.content-height.%@: fractional width %.2fpt left the caption-hidden row at a stale height (inbox %.3f, cell %.3f, tier %@, project hidden %@, height %.1f wanted %.1f)",
                    appearanceName.rawValue, fractionalBelow,
                    transitionProbe.inbox.bounds.width,
                    fractionalNarrowGeometry?.elementFrames["cell"]?.width ?? -1,
                    fractionalNarrowGeometry?.fitTier?.rawValue ?? "nil",
                    String(describing: fractionalNarrowGeometry?.labels.first(where: { $0.element == "project" })?.isHidden),
                    fractionalNarrowHeight ?? -1, transitionOneLineHeight))
            }
            try expectRenameEditorToFollowTitle("the fractional tier crossing")
            asserted += 3

            transitionProbe.window.setContentSize(
                NSSize(width: CGFloat(WorkspaceSidebarConfig.minWidth), height: maxHeight))
            layoutTransitionHost(width: CGFloat(WorkspaceSidebarConfig.minWidth))
            guard let narrowGeometry = transitionProbe.inbox.qaRowGeometriesForQA.first,
                  narrowGeometry.fitTier == .captionHidden,
                  narrowGeometry.labels.first(where: { $0.element == "project" })?.isHidden == true,
                  let narrowHeight = transitionProbe.inbox.rowHeightForQA(id: resizingRow.id),
                  // Negative witness observed on the final check: expecting the
                  // two-line height here exited 1 at the exact message
                  // `sidebar-ux-check.content-height.NSAppearanceNameAqua: width transition left the caption-hidden row at the stale two-line height`.
                  // The source was restored and its SHA-256 matched before green.
                  abs(narrowHeight - transitionOneLineHeight) <= 0.5 else {
                throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): width transition left the caption-hidden row at the stale two-line height")
            }

            try expectRenameEditorToFollowTitle("the minimum-width resize")

            transitionProbe.window.setContentSize(
                NSSize(width: CGFloat(WorkspaceSidebarConfig.defaultWidth), height: maxHeight))
            layoutTransitionHost(width: CGFloat(WorkspaceSidebarConfig.defaultWidth))
            try expectRenameEditorToFollowTitle("the default-width resize")
            let middleTier = AgentInboxCellView.fitTier(
                for: resizingRow,
                available: CGFloat(WorkspaceSidebarConfig.defaultWidth) - Inset.card.horizontal,
                disclosure: .none)
            let middleExpectedHeight = Metrics.rowHeight(
                for: middleTier.drawsProject ? [.label, .title] : [.title],
                insets: Inset.card, spacing: Space.s)
            let middleGeometry = transitionProbe.inbox.qaRowGeometriesForQA.first
            let middleHeight = transitionProbe.inbox.rowHeightForQA(id: resizingRow.id)
            guard middleGeometry?.fitTier == middleTier,
                  middleGeometry?.labels.first(where: { $0.element == "project" })?.isHidden == !middleTier.drawsProject,
                  let middleHeight,
                  abs(middleHeight - middleExpectedHeight) <= 0.5 else {
                throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): live 280pt transition disagreed with its measured tier")
            }

            transitionProbe.window.setContentSize(NSSize(width: 320, height: maxHeight))
            layoutTransitionHost(width: 320)
            let restoredGeometry = transitionProbe.inbox.qaRowGeometriesForQA.first
            let restoredHeight = transitionProbe.inbox.rowHeightForQA(id: resizingRow.id)
            guard restoredGeometry?.fitTier == .full,
                  restoredGeometry?.labels.first(where: { $0.element == "project" })?.isHidden == false,
                  let restoredHeight,
                  abs(restoredHeight - transitionTwoLineHeight) <= 0.5 else {
                throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): widening the row left its restored project band at the stale one-line height (inbox width \(transitionProbe.inbox.bounds.width), cell width \(restoredGeometry?.elementFrames["cell"]?.width ?? -1), tier \(restoredGeometry?.fitTier?.rawValue ?? "nil"), height \(restoredHeight ?? -1), project hidden \(String(describing: restoredGeometry?.labels.first(where: { $0.element == "project" })?.isHidden)))")
            }
            try expectRenameEditorToFollowTitle("the restored wide resize")
            _ = transitionProbe.inbox.pressKeyInRenameForQA(#selector(NSResponder.cancelOperation(_:)))
            asserted += 8

            // P6.5 height-cache witness: keep ONE live host and a genuinely
            // capped parent (>8 direct children). The hidden ninth child is an
            // approval, so the real remainder rollup stays visible while the
            // same host crosses 320→220→280. At 280 the test presses the REAL
            // remainder affordance, then returns to 320 with the expanded parent.
            // Every number below comes from the live table rect, not a model-only
            // height accessor; the expected line roles are independently fixed by
            // the visible project/meta labels and the explicit hidden rollup.
            // Negative witness observed against the final check: mutating
            // `AgentInboxView.height`'s `let drawsRollup = Self.drawsRollup(...)`
            // to `let drawsRollup = false` (mutated-file SHA-256
            // `e64ae3b6d2e51851c73f1e2c30fbc62eaa55c4ae8e49388de0ae1988bea43d7d`),
            // rebuilding, and running `--sidebar-ux-check` exited 1 at the exact
            // message `sidebar-ux-check.content-height.NSAppearanceNameAqua: cached parent height at 320pt capped was 61.0, wanted 79.0 from the live project+name+rollup bands`.
            // The source was restored byte-for-byte (restored-file SHA-256
            // `4760b3b02dd89e2dc6f9e1875643f53566a76315e1e5e2abc280c9af58112d7c`)
            // before the rebuilt geometry check exited 0.
            let rollupParentID = UUID(uuidString: "5A000000-0000-4000-8000-000000000006")!
            let rollupChildIDs = (0..<9).map { index in
                UUID(uuidString: String(format: "5A000000-0000-4000-8000-%012d", index + 8))!
            }
            let rollupParent = AgentInboxRow(
                id: rollupParentID, title: "Rollup height parent", projectName: resizingProject,
                state: .ready, attention: .none, model: nil, role: nil, branch: nil,
                elapsed: nil, createdAt: epoch.addingTimeInterval(20))
            let rollupChildren = rollupChildIDs.enumerated().map { index, childID in
                AgentInboxRow(
                    id: childID, title: "Hidden approval \(index)", state: .approval,
                    attention: .none, model: nil, role: nil, branch: nil,
                    lastActiveAt: epoch.addingTimeInterval(Double(19 - index)),
                    depth: 1, createdAt: epoch.addingTimeInterval(Double(19 - index)),
                    parentId: rollupParentID)
            }
            let cappedRollupRows = [rollupParent] + rollupChildren
            let cappedRollupSorted = InboxSort.sortForInbox(rows: cappedRollupRows)
            let cappedRollupDefault = InboxSort.boundedForInbox(rows: cappedRollupSorted)
            guard cappedRollupDefault.rows.count == 1 + InboxSort.maxVisibleChildren,
                  cappedRollupDefault.remainders.count == 1,
                  cappedRollupDefault.remainders.first?.parentId == rollupParentID,
                  cappedRollupDefault.remainders.first?.hiddenChildIDs == [rollupChildIDs[8]] else {
                throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): height witness did not construct a capped ninth-child remainder")
            }
            transitionProbe.inbox.reload(rows: cappedRollupRows)

            func assertCappedHeight(
                at width: CGFloat, phase: String, remainderExpected: Bool
            ) throws {
                layoutTransitionHost(width: width, setWindowContentSize: true)
                guard let geometry = transitionProbe.inbox.qaRowGeometriesForQA.first(where: { $0.agentID == rollupParentID }),
                      let project = geometry.labels.first(where: { $0.element == "project" }),
                      let meta = geometry.labels.first(where: { $0.element == "meta" }) else {
                    throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): capped height witness did not materialize its parent at \(phase)")
                }
                if remainderExpected {
                    guard !meta.isHidden, meta.text.contains("1 needs you") else {
                        throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): capped parent rollup disappeared at \(phase)")
                    }
                } else {
                    guard meta.isHidden || meta.text.isEmpty else {
                        throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): expanded parent retained a stale capped rollup at \(phase)")
                    }
                }
                let projectVisible = !project.isHidden
                let roles: [TextRole]
                if remainderExpected {
                    roles = projectVisible ? [.label, .title, .label] : [.title, .label]
                } else {
                    roles = projectVisible ? [.label, .title] : [.title]
                }
                let expectedParentHeight = Metrics.rowHeight(
                    for: roles, insets: Inset.card, spacing: Space.s)
                guard let actualParentHeight = transitionProbe.inbox.rowHeightForQA(id: rollupParentID),
                      abs(actualParentHeight - expectedParentHeight) <= 0.5 else {
                    throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): cached parent height at \(phase) was \(transitionProbe.inbox.rowHeightForQA(id: rollupParentID) ?? -1), wanted \(expectedParentHeight) from the live \(projectVisible ? "project+name+rollup" : "name+rollup") bands")
                }
                if remainderExpected {
                    guard let remainderHeight = transitionProbe.inbox.fanoutRemainderHeightForQA(parentId: rollupParentID),
                          abs(remainderHeight - AgentInboxView.slimRowHeight) <= 0.5,
                          transitionProbe.inbox.fanoutRemainderRowsForQA.map(\.parentId) == [rollupParentID],
                          transitionProbe.inbox.tableRowCountForQA
                            == transitionProbe.inbox.qaMaterializedRowCellCount + 1 else {
                        throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): cached remainder height or table accounting was stale at \(phase)")
                    }
                } else {
                    guard transitionProbe.inbox.fanoutRemainderHeightForQA(parentId: rollupParentID) == nil,
                          transitionProbe.inbox.fanoutRemainderRowsForQA.isEmpty,
                          transitionProbe.inbox.tableRowCountForQA
                            == transitionProbe.inbox.qaMaterializedRowCellCount else {
                        throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): expanded remainder row remained in the live table at \(phase)")
                    }
                }
            }

            // The sequence is intentionally on one host/window: the table's old
            // row-height cache survives each width change and is observed again.
            try assertCappedHeight(at: 320, phase: "320pt capped", remainderExpected: true)
            try assertCappedHeight(
                at: CGFloat(WorkspaceSidebarConfig.minWidth),
                phase: "220pt capped", remainderExpected: true)
            try assertCappedHeight(
                at: CGFloat(WorkspaceSidebarConfig.defaultWidth),
                phase: "280pt capped", remainderExpected: true)
            guard transitionProbe.inbox.clickFanoutRemainderForQA(parentId: rollupParentID) else {
                throw fail("sidebar-ux-check.content-height.\(appearanceName.rawValue): height witness could not press the live remainder affordance")
            }
            try assertCappedHeight(at: 320, phase: "320pt expanded", remainderExpected: false)
            asserted += 8
        }

        // The same content with a different resting mark/lifecycle must not move
        // the card. This is the non-vacuous guard against height branching on
        // attention or importance rather than on what the cell draws.
        let base = rows[1]
        let equivalent = AgentInboxRow(
            id: base.id, title: base.title, projectName: base.projectName,
            state: base.state, attention: .unread, lifecycle: .archived,
            model: base.model, role: base.role, branch: base.branch,
            isIsolated: base.isIsolated, elapsed: base.elapsed, depth: base.depth,
            variant: .card, createdAt: base.createdAt, parentId: base.parentId)
        guard AgentInboxView.height(for: base) == AgentInboxView.height(for: equivalent) else {
            throw fail("sidebar-ux-check.content-height: identical drawn content changed height with attention/lifecycle")
        }

        // A content arrival changes only the row's height; the selected identity
        // and the visible scroll anchor stay put through the incremental reload.
        let scrollRows = (0..<7).map { index -> AgentInboxRow in
            AgentInboxRow(
                id: UUID(uuidString: String(format: "5A000000-0000-4000-8000-%012d", index + 100))!,
                title: "Scroll \(index)",
                state: .ready, attention: .none,
                model: nil, role: nil, branch: nil, elapsed: nil,
                variant: .card, createdAt: epoch.addingTimeInterval(Double(index + 10)))
        }
        // InboxSort puts the newest active row first. Change row 5, which is
        // immediately before row 4 in the rendered order, so the content arrival
        // is a visible/preceding-row change rather than an offscreen tail update.
        let arriving = AgentInboxRow(
            id: scrollRows[5].id, title: scrollRows[5].title, projectName: "continuum",
            state: .ready, attention: .none, model: "gpt-5.6-sol", role: "builder",
            branch: "agent/arriving", elapsed: nil, variant: .card,
            createdAt: scrollRows[5].createdAt)
        let nextScrollRows = scrollRows.map { $0.id == arriving.id ? arriving : $0 }
        let oneLineHeight = Metrics.rowHeight(
            for: [.title], insets: Inset.card, spacing: Space.s)
        let threeLineHeight = Metrics.rowHeight(
            for: [.label, .title, .label], insets: Inset.card, spacing: Space.s)
        var incrementalWidths: [String] = []
        // The selected anchor is the row immediately after the arriving row in
        // the newest-first rendered order. It must remain the visible anchor even
        // if AppKit adjusts the document-space clip origin while remeasuring.
        let selectedID = scrollRows[4].id
        for width in widths {
            let scrollProbe = try makeSidebarProbeHost(
                width: width, height: 190, appearanceName: .aqua)
            scrollProbe.inbox.reload(rows: scrollRows)
            scrollProbe.inbox.layoutForQA()
            scrollProbe.host.layoutSubtreeIfNeeded()
            scrollProbe.inbox.layoutForQA()
            guard scrollProbe.inbox.selectRowForQA(id: selectedID) else {
                throw fail("sidebar-ux-check.content-height@\(Int(width))pt: could not select the scroll anchor row")
            }
            scrollProbe.inbox.scrollForQA(byPoints: AgentInboxView.rowHeight)
            let offsetBefore = scrollProbe.inbox.contentOffsetYForQA
            let visibleBefore = scrollProbe.inbox.visibleAgentIdsForQA
            guard visibleBefore.contains(arriving.id), visibleBefore.contains(selectedID),
                  let anchorFrameBefore = scrollProbe.inbox.rowFrameInViewportForQA(id: selectedID),
                  let anchorDocumentBefore = scrollProbe.inbox.tableRowFrameForQA(id: selectedID) else {
                throw fail("sidebar-ux-check.content-height@\(Int(width))pt: visible scroll anchor was not materialized before content arrival (visible \(visibleBefore.map(\.uuidString)))")
            }
            guard let beforeHeight = scrollProbe.inbox.rowHeightForQA(id: arriving.id),
                  abs(beforeHeight - oneLineHeight) <= 0.5 else {
                throw fail(String(
                    format: "sidebar-ux-check.content-height@%.0fpt: arriving row started at %.1fpt, wanted %.1fpt before content arrived",
                    width, scrollProbe.inbox.rowHeightForQA(id: arriving.id) ?? -1, oneLineHeight))
            }

            scrollProbe.inbox.apply(
                rows: nextScrollRows,
                changed: AgentsBoardChangeSet(added: [], updated: [arriving.id], removed: []))
            scrollProbe.host.layoutSubtreeIfNeeded()
            scrollProbe.inbox.layoutForQA()
            guard let afterHeight = scrollProbe.inbox.rowHeightForQA(id: arriving.id) else {
                throw fail("sidebar-ux-check.content-height@\(Int(width))pt: arriving row has no live post-update height")
            }
            guard abs(afterHeight - threeLineHeight) <= 0.5,
                  afterHeight > beforeHeight + 0.5 else {
                throw fail(String(
                    format: "sidebar-ux-check.content-height@%.0fpt: content arrival left row at %.1fpt (before %.1fpt, wanted %.1fpt) — stale row height cache",
                    width, afterHeight, beforeHeight, threeLineHeight))
            }
            guard let arrivingGeometry = scrollProbe.inbox.qaRowGeometriesForQA.first(where: {
                $0.agentID == arriving.id
            }), arrivingGeometry.fitTier == .full else {
                throw fail("sidebar-ux-check.content-height@\(Int(width))pt: arriving three-line witness did not draw its complete content")
            }
            guard scrollProbe.inbox.selectedRowIdsForQA == [selectedID] else {
                throw fail("sidebar-ux-check.content-height@\(Int(width))pt: selection did not survive a content-derived row height change")
            }
            let visibleAfter = scrollProbe.inbox.visibleAgentIdsForQA
            let anchorDocumentAfter = scrollProbe.inbox.tableRowFrameForQA(id: selectedID)
            guard visibleAfter.contains(selectedID),
                  let anchorFrameAfter = scrollProbe.inbox.rowFrameInViewportForQA(id: selectedID),
                  abs(anchorFrameAfter.minY - anchorFrameBefore.minY) <= 0.5 else {
                throw fail(String(
                    format: "sidebar-ux-check.content-height@%.0fpt: visible anchor moved or disappeared when content arrived (before y %.1f, after y %.1f, visible %@)",
                    width, anchorFrameBefore.minY,
                    scrollProbe.inbox.rowFrameInViewportForQA(id: selectedID)?.minY ?? -1,
                    visibleAfter.map(\.uuidString).joined(separator: ","))
                    + " (offset before " + String(format: "%.1f", offsetBefore)
                    + ", after " + String(format: "%.1f", scrollProbe.inbox.contentOffsetYForQA)
                    + ", document y before " + String(format: "%.1f", anchorDocumentBefore.minY)
                    + ", after " + String(format: "%.1f", anchorDocumentAfter?.minY ?? -1) + ")")
            }
            incrementalWidths.append("\(Int(width))pt=\(String(format: "%.1f→%.1f", beforeHeight, afterHeight))")
            asserted += 4
        }

        // A shrink at the bottom is a separate anchor case. AppKit is allowed to
        // constrain the clip origin when the document becomes shorter; restoring
        // an old document-space delta after that constraint double-applies it.
        // The row immediately after the shrinking row is the visible anchor, so
        // its viewport position—not an assumed numeric offset—proves the result.
        let bottomRows: [AgentInboxRow] = (0..<6).map { index in
            AgentInboxRow(
                id: UUID(uuidString: String(format: "5A000000-0000-4000-8000-%012d", index + 200))!,
                title: "Bottom \(index)", projectName: "continuum", state: .working,
                attention: .none, model: nil, role: "builder", branch: "agent/full",
                isIsolated: true, elapsed: 30, variant: .card,
                createdAt: epoch.addingTimeInterval(Double(index + 30)))
        }
        let shrinkingID = bottomRows[1].id
        let bottomAnchorID = bottomRows[0].id
        let bottomNextRows = bottomRows.map { row in
            guard row.id == shrinkingID else { return row }
            return AgentInboxRow(
                id: row.id, title: row.title, state: .ready, attention: .none,
                variant: .card, createdAt: row.createdAt)
        }
        let bottomOneLineHeight = Metrics.rowHeight(
            for: [.title], insets: Inset.card, spacing: Space.s)
        for width in widths {
            let bottomProbe = try makeSidebarProbeHost(
                width: width, height: 190, appearanceName: .aqua)
            bottomProbe.inbox.reload(rows: bottomRows)
            bottomProbe.inbox.layoutForQA()
            bottomProbe.host.layoutSubtreeIfNeeded()
            bottomProbe.inbox.layoutForQA()
            guard Array(bottomProbe.inbox.rowIdsForQA.suffix(2)) == [shrinkingID, bottomAnchorID] else {
                throw fail("sidebar-ux-check.content-height@\(Int(width))pt: bottom shrink witness did not place its changing row immediately before the anchor")
            }
            guard bottomProbe.inbox.selectRowForQA(id: bottomAnchorID) else {
                throw fail("sidebar-ux-check.content-height@\(Int(width))pt: could not select the bottom visible anchor")
            }
            bottomProbe.inbox.scrollToBottomForQA()
            guard bottomProbe.inbox.isAtBottomForQA else {
                throw fail("sidebar-ux-check.content-height@\(Int(width))pt: bottom-shrink witness did not reach the constrained document bottom")
            }
            let visibleBefore = bottomProbe.inbox.visibleAgentIdsForQA
            guard visibleBefore.contains(shrinkingID), visibleBefore.contains(bottomAnchorID),
                  let anchorBefore = bottomProbe.inbox.rowFrameInViewportForQA(id: bottomAnchorID),
                  let beforeHeight = bottomProbe.inbox.rowHeightForQA(id: shrinkingID),
                  abs(beforeHeight - threeLineHeight) <= 0.5 else {
                throw fail("sidebar-ux-check.content-height@\(Int(width))pt: bottom-shrink witness did not materialize both rows at the expected three-line height")
            }

            bottomProbe.inbox.apply(
                rows: bottomNextRows,
                changed: AgentsBoardChangeSet(added: [], updated: [shrinkingID], removed: []))
            bottomProbe.host.layoutSubtreeIfNeeded()
            bottomProbe.inbox.layoutForQA()
            guard let afterHeight = bottomProbe.inbox.rowHeightForQA(id: shrinkingID) else {
                throw fail("sidebar-ux-check.content-height@\(Int(width))pt: bottom shrink row lost its live height")
            }
            guard abs(afterHeight - bottomOneLineHeight) <= 0.5,
                  beforeHeight > afterHeight + 0.5 else {
                throw fail(String(
                    format: "sidebar-ux-check.content-height@%.0fpt: bottom shrink changed %.1fpt to %.1fpt, wanted %.1fpt",
                    width, beforeHeight, afterHeight, bottomOneLineHeight))
            }
            guard bottomProbe.inbox.isAtBottomForQA,
                  bottomProbe.inbox.selectedRowIdsForQA == [bottomAnchorID],
                  bottomProbe.inbox.visibleAgentIdsForQA.contains(bottomAnchorID),
                  let anchorAfter = bottomProbe.inbox.rowFrameInViewportForQA(id: bottomAnchorID),
                  abs(anchorAfter.minY - anchorBefore.minY) <= 0.5 else {
                throw fail(String(
                    format: "sidebar-ux-check.content-height@%.0fpt: bottom visible anchor moved during shrink (before y %.1f, after y %.1f, offset %.1f, atBottom %@, selected %@, visible %@)",
                    width, anchorBefore.minY,
                    bottomProbe.inbox.rowFrameInViewportForQA(id: bottomAnchorID)?.minY ?? -1,
                    bottomProbe.inbox.contentOffsetYForQA,
                    String(bottomProbe.inbox.isAtBottomForQA),
                    bottomProbe.inbox.selectedRowIdsForQA.map(\.uuidString).joined(separator: ","),
                    bottomProbe.inbox.visibleAgentIdsForQA.map(\.uuidString).joined(separator: ",")))
            }
            asserted += 4
        }

        print("UIProbeGeometry: content-derived sidebar heights measured 1/2/3-line cards at 220/280/320pt in both appearances (\(measuredHeights.sorted().joined(separator: ", "))); caption-hidden sole metadata collapsed; incremental arrival heights \(incrementalWidths.joined(separator: ", ")) preserved selection and scroll, including constrained-bottom shrink")
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

    // MARK: - P2.6 — slim variant parity

    /// The slim row reuses the card's surface view, but this gate drives the
    /// interaction inputs through an actual slim cell at every shipping width
    /// and appearance. A card-only ladder would let a separate slim view drift
    /// while all of the existing P1.2/P1.4 checks stayed green.
    private static func checkSidebarSlimVariantParity(
        rows: [AgentInboxRow], probeHeight: CGFloat
    ) throws -> Int {
        guard let slim = rows.first(where: { $0.variant == .slim }),
              let card = rows.first(where: { $0.variant == .card }) else {
            throw fail("sidebar-ux-check.slim-parity: corpus must contain both a slim and a card row")
        }
        let widths: [CGFloat] = [
            CGFloat(WorkspaceSidebarConfig.minWidth),
            CGFloat(WorkspaceSidebarConfig.defaultWidth),
            320,
        ]
        var asserted = 0
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp?.appearance = NSAppearance(named: appearanceName)
            let theme: TokenTheme = appearanceName == .darkAqua ? .dark : .light
            for width in widths {
                let label = "sidebar-ux-check.slim-parity@\(Int(width))pt.\(appearanceName.rawValue)"
                let probe = try makeSidebarProbeHost(
                    width: width, height: probeHeight, appearanceName: appearanceName)
                probe.inbox.clock = { LabFixtures.inboxNow }
                probe.inbox.toggleShelf()
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.reload(rows: rows)
                probe.inbox.layoutForQA()
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.layoutForQA()

                func geometry(for id: UUID) throws -> AgentInboxRowGeometryForQA {
                    guard let geometry = probe.inbox.qaRowGeometriesForQA.first(where: { $0.agentID == id }) else {
                        throw fail("\(label): missing live geometry for \(id.uuidString)")
                    }
                    return geometry
                }

                // Resting paint is the same unfilled card surface, with the same
                // zero perimeter and no shadow, on both cell classes.
                let restingCard = try geometry(for: card.id)
                let restingSlim = try geometry(for: slim.id)
                for (row, geometry) in [(card, restingCard), (slim, restingSlim)] {
                    guard geometry.surfaceRole == .resting else {
                        throw fail("\(label): \(row.title) resting row resolved \(geometry.surfaceRole?.rawValue ?? "nil")")
                    }
                    try expectRowFill(geometry, role: .resting, row: row, theme: theme, label: label)
                    try expectRowLines(geometry, row: row, label: label)
                }
                guard hex(restingCard.resolvedFill) == hex(restingSlim.resolvedFill) else {
                    throw fail("\(label): card and slim resting rows do not share one fill")
                }
                asserted += 1

                // Selection is the same fill on both variants; the live tree,
                // rather than the shared class name, is the assertion.
                guard probe.inbox.selectRowsForQA(ids: [card.id, slim.id]) else {
                    throw fail("\(label): card and slim rows could not both be selected")
                }
                probe.inbox.rebuildRowsForQA()
                let selectedCard = try geometry(for: card.id)
                let selectedSlim = try geometry(for: slim.id)
                guard selectedCard.surfaceRole == .selected,
                      selectedSlim.surfaceRole == .selected,
                      hex(selectedCard.resolvedFill) == hex(selectedSlim.resolvedFill) else {
                    throw fail("\(label): card/slim selection did not resolve to one shared fill")
                }
                for (row, geometry) in [(card, selectedCard), (slim, selectedSlim)] {
                    try expectRowLines(geometry, row: row, label: label)
                }
                asserted += 1

                // Hover must outrank the quieter selected state on the slim
                // variant too, without borrowing a border or shadow.
                guard probe.inbox.hoverRowForQA(id: slim.id) else {
                    throw fail("\(label): slim row could not be hovered")
                }
                probe.inbox.rebuildRowsForQA()
                let hoveredSlim = try geometry(for: slim.id)
                guard hoveredSlim.surfaceRole == .hover else {
                    throw fail("\(label): hovered slim row resolved \(hoveredSlim.surfaceRole?.rawValue ?? "nil")")
                }
                try expectRowFill(hoveredSlim, role: .hover, row: slim, theme: theme, label: label)
                try expectRowLines(hoveredSlim, row: slim, label: label)
                asserted += 1

                // Route-active is the loudest step, and focus is a separate
                // temporary ring. Both are asked of the slim cell itself.
                _ = probe.inbox.hoverRowForQA(id: nil)
                probe.inbox.openAgentId = slim.id
                probe.inbox.layoutForQA()
                probe.inbox.rebuildRowsForQA()
                let activeSlim = try geometry(for: slim.id)
                guard activeSlim.surfaceRole == .active else {
                    throw fail("\(label): route-active slim row resolved \(activeSlim.surfaceRole?.rawValue ?? "nil")")
                }
                try expectRowFill(activeSlim, role: .active, row: slim, theme: theme, label: label)
                try expectRowLines(activeSlim, row: slim, label: label)
                asserted += 1

                probe.inbox.openAgentId = nil
                guard probe.inbox.selectRowForQA(id: slim.id),
                      probe.inbox.focusRowByKeyboardForQA(id: slim.id) else {
                    throw fail("\(label): slim row could not take keyboard focus")
                }
                probe.inbox.rebuildRowsForQA()
                let focusedSlim = try geometry(for: slim.id)
                guard focusedSlim.surfaceRole == .selected,
                      focusedSlim.isFocusRingVisible,
                      focusedSlim.paintedLines["focusRing.border"] == LineWidth.hairline,
                      focusedSlim.paintedLines["card.border"] == 0,
                      focusedSlim.paintedLines["card.shadowOpacity"] == 0 else {
                    throw fail("\(label): slim focus treatment did not use the shared hairline ring without a card border")
                }
                asserted += 1
            }
        }
        asserted += try checkSlimTierReachabilityAndDisclosedParent(probeHeight: probeHeight)
        return asserted
    }

    /// Round 2 of P2.6's review: the corpus's slim rows are all top-level
    /// leaves, so the tier ladder's other rungs and the fold triangle's part in
    /// the arithmetic were unproved. Both are proved here on live cells with
    /// rows engineered from their own measurements — the same move as the card
    /// ladder's middle rung, and for the same reason: the corpus may not grow a
    /// fixture (P0.3 is pinned), and a tier nothing reaches is not a tier.
    private static func checkSlimTierReachabilityAndDisclosedParent(
        probeHeight: CGFloat
    ) throws -> Int {
        let settledAt = LabFixtures.inboxNow.addingTimeInterval(-300)
        func slimRow(_ id: String, title: String, branch: String? = nil, parent: UUID? = nil) -> AgentInboxRow {
            AgentInboxRow(
                id: UUID(uuidString: id)!, title: title, projectName: nil,
                state: .ready, lifecycle: .settled(at: settledAt),
                model: "openai-codex/gpt-5.6-luna", branch: branch,
                createdAt: settledAt.addingTimeInterval(-60), parentId: parent)
        }
        // Reached tiers, engineered: a short leaf that must keep everything, a
        // branched leaf whose branch is wider than a 220pt line, and a leaf
        // whose name alone is wider than a 320pt line.
        let tiny = slimRow("6D000000-0000-4000-8000-000000000001", title: "Fix")
        let branchy = slimRow(
            "6D000000-0000-4000-8000-000000000002", title: "Nightly rebase",
            branch: "agent/very-long-branch-name-that-cannot-share-a-narrow-line")
        let sprawl = slimRow(
            "6D000000-0000-4000-8000-000000000003",
            title: String(repeating: "measured ", count: 12))
        var asserted = 0
        var reached = Set<SlimRowFitTier>()
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp?.appearance = NSAppearance(named: appearanceName)
            for width in [CGFloat(WorkspaceSidebarConfig.minWidth), 320] {
                let label = "sidebar-ux-check.slim-tiers@\(Int(width))pt.\(appearanceName.rawValue)"
                let probe = try makeSidebarProbeHost(
                    width: width, height: probeHeight, appearanceName: appearanceName)
                probe.inbox.clock = { LabFixtures.inboxNow }
                probe.inbox.toggleShelf()
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.reload(rows: [tiny, branchy, sprawl])
                probe.inbox.layoutForQA()
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.layoutForQA()
                for row in [tiny, branchy, sprawl] {
                    guard let geometry = probe.inbox.qaRowGeometriesForQA.first(where: { $0.agentID == row.id }) else {
                        throw fail("\(label): engineered slim row '\(row.title)' did not materialize")
                    }
                    try expectSlimRowFitTier(geometry, row: row, hasChildren: false, label: label)
                    if let tier = geometry.slimFitTier { reached.insert(tier) }
                    asserted += 1
                }
            }
        }
        guard reached == Set(SlimRowFitTier.allCases) else {
            throw fail("sidebar-ux-check.slim-tiers: engineered rows reached only \(reached.map(\.rawValue).sorted().joined(separator: ", ")) — every slim tier must be reached by a live cell (P2.6)")
        }

        // The disclosed parked parent, at a width derived from the row's own
        // measured needs so the triangle is exactly what tips the tier: without
        // it the line fits whole, with it something must yield. An
        // implementation that forgets the triangle in its fit math resolves
        // .full here and disagrees with the oracle.
        NSApp?.appearance = NSAppearance(named: .aqua)
        let probeButton = InboxDisclosureButton()
        probeButton.show(.expanded)
        let disclosureNeed = Double(probeButton.fittingSize.width)
        var parentTitle = "Parked sweep"
        var parent = slimRow("6D000000-0000-4000-8000-000000000010", title: parentTitle)
        let child = slimRow(
            "6D000000-0000-4000-8000-000000000011", title: "Child",
            parent: parent.id)
        let calibration = try makeSidebarProbeHost(
            width: 280, height: probeHeight, appearanceName: .aqua)
        calibration.inbox.clock = { LabFixtures.inboxNow }
        calibration.inbox.toggleShelf()
        calibration.host.layoutSubtreeIfNeeded()
        calibration.inbox.reload(rows: [parent, child])
        calibration.inbox.layoutForQA()
        calibration.host.layoutSubtreeIfNeeded()
        calibration.inbox.layoutForQA()
        guard let calibrated = calibration.inbox.qaRowGeometriesForQA.first(where: { $0.agentID == parent.id }),
              let calibratedCard = calibrated.elementFrames["card"],
              let titleGeometry = calibrated.labels.first(where: { $0.element == "title" }),
              let glyphGeometry = calibrated.labels.first(where: { $0.element == "glyph" }),
              let titleFont = titleGeometry.font else {
            throw fail("sidebar-ux-check.slim-disclosure: the parked parent did not materialize at the calibration width")
        }
        // available(280) tells us the chrome the probe adds around the line.
        let chrome = 280 - (Double(calibratedCard.width) - Inset.row.horizontal)
        func widthOf(_ text: String, _ font: NSFont) -> Double {
            Double(ceil((text as NSString).size(withAttributes: [.font: font]).width)) + Metrics.cellTextInset
        }
        let glyphNeed = glyphGeometry.neededWidth
        let timeNeed = AgentElapsedFormatter.columnLabels
            .flatMap { ["\($0) ago", "in \($0)"] }
            .map { widthOf($0, NSFont.token(.captionMono)) }
            .max() ?? Metrics.cellTextInset
        // Grow the name until line-without-triangle just fits a width inside
        // the shipping range and line-with-triangle does not.
        while true {
            let lineNeed = glyphNeed + Space.m + widthOf(parentTitle, titleFont)
                + Space.m + timeNeed
            let target = lineNeed + chrome + min(Space.m, disclosureNeed) / 2
            if target >= 240 { break }
            parentTitle += "m"
        }
        parent = slimRow("6D000000-0000-4000-8000-000000000010", title: parentTitle)
        let lineNeed = glyphNeed + Space.m + widthOf(parentTitle, titleFont) + Space.m + timeNeed
        let derivedWidth = (lineNeed + chrome + min(Space.m, disclosureNeed) / 2).rounded()
        guard derivedWidth > Double(WorkspaceSidebarConfig.minWidth), derivedWidth < 320 else {
            throw fail(String(
                format: "sidebar-ux-check.slim-disclosure: derived width %.0fpt fell outside the shipping range — recalibrate the parent fixture",
                derivedWidth))
        }
        let probe = try makeSidebarProbeHost(
            width: CGFloat(derivedWidth), height: probeHeight, appearanceName: .aqua)
        probe.inbox.clock = { LabFixtures.inboxNow }
        probe.inbox.toggleShelf()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.reload(rows: [parent, child])
        probe.inbox.layoutForQA()
        probe.host.layoutSubtreeIfNeeded()
        probe.inbox.layoutForQA()
        let label = "sidebar-ux-check.slim-disclosure@\(Int(derivedWidth))pt.aqua"
        guard let parentGeometry = probe.inbox.qaRowGeometriesForQA.first(where: { $0.agentID == parent.id }) else {
            throw fail("\(label): the parked parent did not materialize at its derived width")
        }
        guard parentGeometry.elementFrames["disclosure"] != nil else {
            throw fail("\(label): the parked parent draws no fold triangle")
        }
        guard parentGeometry.slimFitTier == .timeHidden else {
            throw fail("\(label): the triangle's width did not participate in the tier — resolved \(parentGeometry.slimFitTier?.rawValue ?? "nil"), expected timeHidden once the disclosure is paid for (P2.6 round 2)")
        }
        try expectSlimRowFitTier(parentGeometry, row: parent, hasChildren: true, label: label)
        asserted += 2
        return asserted
    }

    // MARK: - P2.5 — one elapsed vocabulary and fixed lanes

    private static func measuredElapsedNeed(_ text: String) -> Double {
        let font = NSFont.token(.captionMono)
        return Double(ceil((text as NSString).size(withAttributes: [.font: font]).width))
            + Metrics.cellTextInset
    }

    private static func checkElapsedFormatterAndColumns() throws -> Int {
        let day = TimeInterval(86_400)
        let cases: [(TimeInterval, String)] = [
            (0, "0s"),
            (59, "59s"),
            (60, "1m"),
            (65, "1m 5s"),
            (3_599, "59m 59s"),
            (3_600, "1h 0m"),
            (86_399, "23h 59m"),
            (86_400, "1d"),
            (6 * day + 21 * 3_600 + 5 * 60, "6d"),
            (999 * day, "999d"),
            (1_000 * day, ">999d"),
            (-1, "0s"),
            (.infinity, "0s"),
            (-.infinity, "0s"),
            (.nan, "0s"),
        ]
        var asserted = 0
        for (seconds, expected) in cases {
            let actual = AgentElapsedFormatter.elapsedLabel(seconds)
            guard actual == expected else {
                throw fail("sidebar-ux-check.elapsed: \(seconds)s formatted as '\(actual)', expected '\(expected)'")
            }
            asserted += 1
        }

        let widestNeed = AgentElapsedFormatter.columnLabels.map(measuredElapsedNeed).max() ?? 0
        guard AgentElapsedFormatter.columnLabels.contains("59m 59s"),
              AgentElapsedFormatter.columnLabels.contains("23h 59m"),
              AgentElapsedFormatter.columnLabels.contains(">999d"),
              widestNeed > 0 else {
            throw fail("sidebar-ux-check.elapsed: columnLabels do not cover the formatter's bounded widest forms")
        }
        for (_, expected) in cases {
            guard measuredElapsedNeed(expected) <= widestNeed + 0.01 else {
                throw fail("sidebar-ux-check.elapsed: formatter emitted '\(expected)' wider than its fixed column (need \(measuredElapsedNeed(expected))pt, lane \(widestNeed)pt)")
            }
            asserted += 1
        }

        let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let now = epoch.addingTimeInterval(100_000)
        let cardID = UUID(uuidString: "5B000000-0000-4000-8000-000000000001")!
        let slimID = UUID(uuidString: "5B000000-0000-4000-8000-000000000002")!
        func card(elapsed: TimeInterval) -> AgentInboxRow {
            AgentInboxRow(
                id: cardID, title: "Elapsed name", projectName: "continuum",
                state: .working, elapsed: elapsed, variant: .card, createdAt: epoch)
        }
        func slim(endedAt: Date) -> AgentInboxRow {
            AgentInboxRow(
                id: slimID, title: "N", state: .ready,
                lifecycle: .settled(at: endedAt), variant: .slim, createdAt: epoch)
        }
        let widths: [CGFloat] = [
            CGFloat(WorkspaceSidebarConfig.minWidth),
            CGFloat(WorkspaceSidebarConfig.defaultWidth),
            320,
        ]
        let height = CGFloat((AgentInboxView.rowHeight + AgentInboxView.scopeControlHeight + 160).rounded(.up))

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp?.appearance = NSAppearance(named: appearanceName)
            for width in widths {
                let cardProbe = try makeSidebarProbeHost(
                    width: width, height: height, appearanceName: appearanceName)
                cardProbe.inbox.reload(rows: [card(elapsed: 65)])
                cardProbe.inbox.layoutForQA()
                cardProbe.host.layoutSubtreeIfNeeded()
                cardProbe.inbox.layoutForQA()
                guard let shortCard = cardProbe.inbox.qaRowGeometriesForQA.first,
                      let shortElapsed = shortCard.labels.first(where: { $0.element == "elapsed" }),
                      let shortTitle = shortCard.labels.first(where: { $0.element == "title" }),
                      !shortElapsed.isHidden, !shortTitle.isHidden else {
                    throw fail("sidebar-ux-check.elapsed@\(Int(width))pt.\(appearanceName.rawValue): card elapsed/name witness did not materialize")
                }
                let shortElapsedWidth = shortElapsed.frame.width
                guard shortElapsed.drawableWidth + 0.5 >= shortElapsed.neededWidth,
                      Double(shortElapsed.frame.width) + 0.5 >= AgentInboxCellView.elapsedColumnWidth else {
                    throw fail(String(format: "sidebar-ux-check.elapsed@%.0fpt.%@: row elapsed string need %.1fpt, drawable %.1fpt, fixed lane %.1fpt",
                                       width, appearanceName.rawValue, shortElapsed.neededWidth,
                                       shortElapsed.drawableWidth, AgentInboxCellView.elapsedColumnWidth))
                }
                cardProbe.inbox.reload(rows: [card(elapsed: 86_399)])
                cardProbe.inbox.layoutForQA()
                cardProbe.host.layoutSubtreeIfNeeded()
                cardProbe.inbox.layoutForQA()
                guard let longCard = cardProbe.inbox.qaRowGeometriesForQA.first,
                      let longElapsed = longCard.labels.first(where: { $0.element == "elapsed" }),
                      let longTitle = longCard.labels.first(where: { $0.element == "title" }),
                      !longElapsed.isHidden, !longTitle.isHidden else {
                    throw fail("sidebar-ux-check.elapsed@\(Int(width))pt.\(appearanceName.rawValue): long card elapsed/name witness did not materialize")
                }
                guard longElapsed.drawableWidth + 0.5 >= longElapsed.neededWidth,
                      Double(longElapsed.frame.width) + 0.5 >= AgentInboxCellView.elapsedColumnWidth else {
                    throw fail(String(format: "sidebar-ux-check.elapsed@%.0fpt.%@: long elapsed string need %.1fpt, drawable %.1fpt, fixed lane %.1fpt",
                                       width, appearanceName.rawValue, longElapsed.neededWidth,
                                       longElapsed.drawableWidth, AgentInboxCellView.elapsedColumnWidth))
                }
                guard abs(shortElapsedWidth - longElapsed.frame.width) <= 0.5 else {
                    throw fail("sidebar-ux-check.elapsed@\(Int(width))pt.\(appearanceName.rawValue): elapsed lane moved from \(shortElapsedWidth)pt to \(longElapsed.frame.width)pt")
                }
                guard abs(shortTitle.drawableWidth - longTitle.drawableWidth) <= 0.5 else {
                    throw fail("sidebar-ux-check.elapsed@\(Int(width))pt.\(appearanceName.rawValue): name drawable width changed from \(shortTitle.drawableWidth)pt to \(longTitle.drawableWidth)pt when only elapsed changed")
                }
                asserted += 4

                let slimProbe = try makeSidebarProbeHost(
                    width: width, height: height, appearanceName: appearanceName)
                slimProbe.inbox.clock = { now }
                slimProbe.inbox.reload(rows: [slim(endedAt: now)])
                slimProbe.inbox.layoutForQA()
                slimProbe.host.layoutSubtreeIfNeeded()
                slimProbe.inbox.layoutForQA()
                guard let shortSlim = slimProbe.inbox.qaRowGeometriesForQA.first,
                      let shortTime = shortSlim.labels.first(where: { $0.element == "time" }),
                      let shortSlimTitle = shortSlim.labels.first(where: { $0.element == "title" }),
                      !shortTime.isHidden, !shortSlimTitle.isHidden else {
                    throw fail("sidebar-ux-check.elapsed.slim@\(Int(width))pt.\(appearanceName.rawValue): row has no live time/name labels")
                }
                slimProbe.inbox.reload(rows: [slim(endedAt: now.addingTimeInterval(-3_599))])
                slimProbe.inbox.layoutForQA()
                slimProbe.host.layoutSubtreeIfNeeded()
                slimProbe.inbox.layoutForQA()
                guard let longSlim = slimProbe.inbox.qaRowGeometriesForQA.first,
                      let longTime = longSlim.labels.first(where: { $0.element == "time" }),
                      let longSlimTitle = longSlim.labels.first(where: { $0.element == "title" }),
                      !longTime.isHidden, !longSlimTitle.isHidden else {
                    throw fail("sidebar-ux-check.elapsed.slim@\(Int(width))pt.\(appearanceName.rawValue): long relative-time witness did not materialize")
                }
                guard longTime.text == "59m 59s ago",
                      longTime.drawableWidth + 0.5 >= longTime.neededWidth,
                      Double(longTime.frame.width) + 0.5 >= AgentInboxSlimCellView.relativeTimeColumnWidth else {
                    throw fail(String(format: "sidebar-ux-check.elapsed.slim@%.0fpt.%@: row rendered '%@' with need %.1fpt, drawable %.1fpt, fixed lane %.1fpt",
                                       width, appearanceName.rawValue, longTime.text,
                                       longTime.neededWidth, longTime.drawableWidth,
                                       AgentInboxSlimCellView.relativeTimeColumnWidth))
                }
                guard abs(shortTime.frame.width - longTime.frame.width) <= 0.5,
                      abs(shortSlimTitle.drawableWidth - longSlimTitle.drawableWidth) <= 0.5 else {
                    throw fail("sidebar-ux-check.elapsed.slim@\(Int(width))pt.\(appearanceName.rawValue): name drawable width changed when only relative time changed")
                }
                asserted += 3
            }
        }
        return asserted
    }

    /// P3.4: observation confidence is asserted over the materialized row cell,
    /// not just over a stamped model value. The same row is read twice after the
    /// injected clock advances; its last-known duration must remain stable and its
    /// live status word must not claim working.
    private static func checkUnconfirmedFrozenClock(rows: [AgentInboxRow]) throws -> Int {
        guard let source = rows.first(where: { $0.state == .working && $0.elapsed != nil }) else {
            throw fail("sidebar-ux-check.unconfirmed: corpus has no working row with a duration witness")
        }
        let row = source.withUnconfirmed()
        var assertions = 0
        var slimQualifierDrawnWhole = false
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(WorkspaceSidebarConfig.minWidth), CGFloat(WorkspaceSidebarConfig.defaultWidth), CGFloat(320)] {
                let probe = try makeSidebarProbeHost(
                    width: width,
                    height: AgentInboxView.rowHeight + AgentInboxView.scopeControlHeight + 80,
                    appearanceName: appearanceName)
                probe.inbox.clock = { LabFixtures.inboxNow }
                // Size first; the list's own layout pass materializes the cell.
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.reload(rows: [row])
                probe.inbox.layoutForQA()
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.layoutForQA()
                guard probe.inbox.stateLabelsForQA == ["Unconfirmed"] else {
                    throw fail("sidebar-ux-check.unconfirmed@\(Int(width))pt.\(appearanceName.rawValue): live row rendered a working status instead of Unconfirmed")
                }
                let firstElapsed = probe.inbox.elapsedLabelsForQA
                guard let cardDuration = AgentInboxCellView.elapsedText(row.elapsed) else {
                    throw fail("sidebar-ux-check.unconfirmed: the working witness lost its duration")
                }
                let expectedCardText = "last seen \(cardDuration)"
                guard firstElapsed == [expectedCardText] else {
                    throw fail("sidebar-ux-check.unconfirmed@\(Int(width))pt.\(appearanceName.rawValue): live row shows \(firstElapsed), expected exactly ['\(expectedCardText)'] — the qualifier must carry the REAL last-known duration")
                }
                guard let elapsedGeometry = probe.inbox.qaRowGeometriesForQA.first?.labels.first(where: { $0.element == "elapsed" }),
                      elapsedGeometry.text == firstElapsed[0],
                      elapsedGeometry.drawableWidth + 0.5 >= elapsedGeometry.neededWidth,
                      elapsedGeometry.drawableWidth + 0.5
                          >= AgentInboxCellView.elapsedColumnWidth(unconfirmed: true) - Metrics.cellTextInset else {
                    let geometry = probe.inbox.qaRowGeometriesForQA.first?.labels.first(where: { $0.element == "elapsed" })
                    throw fail(String(format: "sidebar-ux-check.unconfirmed@%.0fpt.%@: last-known duration '%@' needs %.1fpt but drawable width is %.1fpt (column %.1fpt)",
                                      width, appearanceName.rawValue, firstElapsed.first ?? "", geometry?.neededWidth ?? 0,
                                      geometry?.drawableWidth ?? 0, AgentInboxCellView.elapsedColumnWidth))
                }
                probe.inbox.clock = { LabFixtures.inboxNow.addingTimeInterval(3600) }
                probe.inbox.layoutForQA()
                let secondElapsed = probe.inbox.elapsedLabelsForQA
                guard secondElapsed == firstElapsed else {
                    throw fail("sidebar-ux-check.unconfirmed@\(Int(width))pt.\(appearanceName.rawValue): unconfirmed duration advanced from \(firstElapsed) to \(secondElapsed)")
                }
                assertions += 3

                // The SLIM variant renders the qualifier in its own per-row time
                // lane (review round 2, finding 3): a parked unconfirmed row must
                // draw "last seen …" whole — exact text, drawable width against
                // measured need — or the new lane is a promise only the card kept.
                let parkedSource = source.withUnconfirmed(
                    true, elapsed: source.elapsed)
                let parked = AgentInboxRow(
                    id: parkedSource.id, title: parkedSource.title,
                    projectName: parkedSource.projectName,
                    state: .ready, lifecycle: .settled(at: LabFixtures.inboxNow.addingTimeInterval(-300)),
                    model: parkedSource.model, branch: nil,
                    elapsed: parkedSource.elapsed,
                    createdAt: parkedSource.createdAt).withUnconfirmed()
                probe.inbox.clock = { LabFixtures.inboxNow }
                probe.inbox.toggleShelf()
                probe.inbox.reload(rows: [parked])
                probe.inbox.layoutForQA()
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.layoutForQA()
                guard let slimGeometry = probe.inbox.qaRowGeometriesForQA.first(where: { $0.agentID == parked.id }),
                      slimGeometry.variant == .slim,
                      let slimTime = slimGeometry.labels.first(where: { $0.element == "time" }) else {
                    throw fail("sidebar-ux-check.unconfirmed-slim@\(Int(width))pt.\(appearanceName.rawValue): the parked unconfirmed row did not materialize as a slim cell")
                }
                if slimTime.isHidden {
                    // The ladder may legitimately drop the time at a narrow width
                    // — but a dropped fact relocates to VoiceOver WHOLE (the real
                    // duration, not just the qualifier), and the drawn case must
                    // still occur at the widest shipping width (asserted after
                    // the loop), or the lane is a promise nothing kept.
                    guard let relocatedDuration = AgentInboxCellView.elapsedText(parked.elapsed),
                          slimGeometry.accessibilityLabel?.contains("last seen \(relocatedDuration)") == true else {
                        throw fail("sidebar-ux-check.unconfirmed-slim@\(Int(width))pt.\(appearanceName.rawValue): the ladder dropped the last-known duration without relocating 'last seen …' and its REAL value to VoiceOver — got '\(slimGeometry.accessibilityLabel ?? "nil")'")
                    }
                    assertions += 1
                    continue
                }
                guard let slimDuration = AgentInboxCellView.elapsedText(parked.elapsed) else {
                    throw fail("sidebar-ux-check.unconfirmed-slim: the parked witness lost its duration")
                }
                let expectedSlimText = "last seen \(slimDuration)"
                guard slimTime.text == expectedSlimText,
                      slimTime.drawableWidth + 0.5 >= slimTime.neededWidth,
                      Double(slimTime.frame.width) + 0.5
                          >= AgentInboxSlimCellView.relativeTimeColumnWidth(unconfirmed: true) else {
                    throw fail(String(
                        format: "sidebar-ux-check.unconfirmed-slim@%.0fpt.%@: '%@' needs %.1fpt but drawable width is %.1fpt (lane %.1fpt, per-row lane %.1fpt)",
                        width, appearanceName.rawValue, slimTime.text, slimTime.neededWidth,
                        slimTime.drawableWidth, Double(slimTime.frame.width),
                        AgentInboxSlimCellView.relativeTimeColumnWidth(unconfirmed: true)))
                }
                slimQualifierDrawnWhole = true
                assertions += 1
            }
        }
        guard slimQualifierDrawnWhole else {
            throw fail("sidebar-ux-check.unconfirmed-slim: no shipping width drew the slim 'last seen' qualifier whole — the per-row lane is untested")
        }
        return assertions
    }

    // MARK: - P4.3 — live rename event path

    /// Exercise the actual row-cell/editor path at every shipping width and both
    /// appearances. The helpers below only stand in for NSEvent delivery; the
    /// editor, delegate, hit test, table activation path and callback are live.
    private static func checkSidebarRenameInteraction() throws -> Int {
        let rows = LabFixtures.inboxRows()
        guard let target = rows.first(where: { row in rows.contains { $0.parentId == row.id } }) else {
            throw fail("sidebar-ux-check.rename: fixture has no parent row with a live nested control")
        }
        let widths: [CGFloat] = [
            CGFloat(WorkspaceSidebarConfig.minWidth),
            CGFloat(WorkspaceSidebarConfig.defaultWidth),
            320,
        ]
        let height = CGFloat(
            (Double(rows.count + 2) * (AgentInboxView.rowHeight + Space.s)
                + AgentInboxView.scopeControlHeight + 120).rounded(.up))
        var assertions = 0

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for width in widths {
                let label = "sidebar-ux-check.rename@\(Int(width))pt.\(appearanceName.rawValue)"
                let probe = try makeSidebarProbeHost(
                    width: width, height: height, appearanceName: appearanceName)
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.reload(rows: rows)
                probe.inbox.layoutForQA()
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.layoutForQA()

                var reveals: [UUID] = []
                probe.inbox.onRevealRow = { reveals.append($0) }

                // A modified double-click is a selection gesture, never an edit.
                guard !probe.inbox.doubleClickRowForQA(
                    id: target.id, onTitle: true, modifiers: [.command]),
                      !probe.inbox.isRenameEditingForQA else {
                    throw fail("\(label): modified double-click opened the live rename editor")
                }
                assertions += 1

                // The disclosure button is a real nested control. Its live frame is
                // required; a row without one cannot make this negative assertion.
                guard let nestedControlFrame = probe.inbox.renameNestedControlFrameForQA(id: target.id),
                      nestedControlFrame.width > 0, nestedControlFrame.height > 0,
                      !probe.inbox.doubleClickNestedControlForQA(id: target.id),
                      !probe.inbox.isRenameEditingForQA else {
                    throw fail("\(label): double-clicking the live disclosure control opened rename")
                }
                assertions += 1

                // Body hit, not only title hit, must open the real field. A second
                // double-click while it is open is refused and leaves typed text in
                // that same field rather than committing/switching rows.
                guard probe.inbox.doubleClickRowForQA(id: target.id, onTitle: false),
                      probe.inbox.isRenameEditingForQA,
                      probe.inbox.typeRenameForQA("still editing"),
                      !probe.inbox.doubleClickRowForQA(id: target.id, onTitle: true),
                      probe.inbox.renameFieldTextForQA == "still editing" else {
                    throw fail("\(label): body edit or already-editing guard did not use the live field")
                }
                assertions += 2

                // The pending table action is the trailing click of that same
                // double-click. It must not reach the reveal callback.
                guard !probe.inbox.trailingClickForQA(id: target.id), reveals.isEmpty else {
                    throw fail("\(label): trailing double-click action activated the row")
                }
                assertions += 1
                guard probe.inbox.pressKeyInRenameForQA(#selector(NSResponder.cancelOperation(_:))),
                      !probe.inbox.isRenameEditingForQA else {
                    throw fail("\(label): Escape did not cancel the live editor")
                }
                assertions += 1

                let initialCommits = probe.inbox.renameCommitCountForQA
                let initialCancels = probe.inbox.renameCancelCountForQA
                guard probe.inbox.doubleClickRowForQA(id: target.id, onTitle: true),
                      probe.inbox.typeRenameForQA("Return name"),
                      probe.inbox.pressKeyInRenameForQA(#selector(NSResponder.insertNewline(_:))),
                      probe.inbox.renameCommitCountForQA == initialCommits + 1,
                      !probe.inbox.isRenameEditingForQA else {
                    throw fail("\(label): Return did not commit exactly one live rename")
                }
                assertions += 2
                // AppKit may report blur after Return. Send that real notification
                // from the ended field and prove the callback count stays single.
                guard probe.inbox.blurAfterReturnForQA(),
                      probe.inbox.renameCommitCountForQA == initialCommits + 1 else {
                    throw fail("\(label): blur after Return double-committed the live rename")
                }
                assertions += 1

                guard probe.inbox.doubleClickRowForQA(id: target.id, onTitle: false),
                      probe.inbox.typeRenameForQA("discarded"),
                      probe.inbox.pressKeyInRenameForQA(#selector(NSResponder.cancelOperation(_:))),
                      probe.inbox.renameCommitCountForQA == initialCommits + 1,
                      probe.inbox.renameCancelCountForQA == initialCancels + 1 else {
                    throw fail("\(label): Escape changed the live name or did not cancel exactly once")
                }
                assertions += 2

                guard probe.inbox.doubleClickRowForQA(id: target.id, onTitle: false),
                      probe.inbox.typeRenameForQA("blur name"),
                      probe.inbox.blurRenameForQA(),
                      probe.inbox.renameCommitCountForQA == initialCommits + 2,
                      !probe.inbox.isRenameEditingForQA else {
                    throw fail("\(label): blur did not commit exactly once through the live field")
                }
                assertions += 2

                // Empty input closes the editor but dispatches no rename callback.
                guard probe.inbox.doubleClickRowForQA(id: target.id, onTitle: true),
                      probe.inbox.typeRenameForQA("   "),
                      probe.inbox.pressKeyInRenameForQA(#selector(NSResponder.insertNewline(_:))),
                      probe.inbox.renameCommitCountForQA == initialCommits + 2,
                      !probe.inbox.isRenameEditingForQA else {
                    throw fail("\(label): empty rename dispatched or failed to close the live editor")
                }
                assertions += 2
            }
        }
        return assertions
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
        // behind a footer that is not an agent cell. The corpus keeps its settled
        // tail within the first page; a packet that needs a longer tail must
        // expand paging here first.
        let settledRows = rows.filter { InboxSort.section(for: $0.lifecycle, now: LabFixtures.inboxNow) == .settled }.count
        guard settledRows <= InboxSort.settledPageSize else {
            throw fail("sidebar-ux-check: corpus has \(settledRows) settled rows, past the \(InboxSort.settledPageSize)-row first page — expand paging in the probe before asserting cells == rows")
        }
        // P0.3: derive the host height from both the collapsed bounded contract
        // and the real expansion contract. A viewport must not make either state
        // pass by truncating rows that should be accounted for.
        let probeHeight = sidebarProbeHeight(for: rows)
        let widths: [CGFloat] = [
            CGFloat(WorkspaceSidebarConfig.minWidth),
            CGFloat(WorkspaceSidebarConfig.defaultWidth),
            320,
        ]
        var totalCells = 0
        var totalLabels = 0
        var totalTruncated = 0
        var observedTiers = Set<RowFitTier>()
        var observedSlimTiers = Set<SlimRowFitTier>()
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
                observedSlimTiers.formUnion(counts.slimTiers)
            }
        }
        _ = try checkSidebarContentDerivedHeights()
        // P1.2/P1.4: the four-state ladder and the focus ring, driven through the
        // view's own hover / selection / route-active / keyboard inputs.
        let ladderAssertions = try checkSidebarInteractionLadder(rows: rows, probeHeight: probeHeight)
        let slimParityAssertions = try checkSidebarSlimVariantParity(
            rows: rows, probeHeight: probeHeight)
        // P2.2: the measured-fit tier ladder as arithmetic, plus the requirement
        // that every named tier is actually REACHED by a real row at a shipping
        // width. A tier nothing resolves to is a sacrifice nobody makes, and it
        // would let the ladder be satisfied by declaring three cases and using
        // one.
        let tierAssertions = try checkSidebarFitTierLadder()
        let elapsedAssertions = try checkElapsedFormatterAndColumns()
        let unconfirmedAssertions = try checkUnconfirmedFrozenClock(rows: rows)
        let renameAssertions = try checkSidebarRenameInteraction()
        let filterBandAssertions = try checkSidebarFilterBand(rows: rows, probeHeight: probeHeight)
        let bulkAssertions = try checkSidebarBulkActionBar(rows: rows, probeHeight: probeHeight)
        let accessibilityMotionAssertions = try checkSidebarAccessibilityMotion(
            rows: rows, probeHeight: probeHeight)
        // Both ENDS of the ladder are reached by real rows at shipping widths. The
        // middle rung is reached too, at a width derived from a row's own
        // measurements inside `checkSidebarFitTierLadder` — see the note there for
        // why the corpus cannot express it at 220/280/320 and why this packet may
        // not add a fixture that would.
        guard observedTiers.contains(.full), observedTiers.contains(.captionHidden) else {
            throw fail("sidebar-ux-check: the corpus reached only \(observedTiers.map(\.rawValue).sorted().joined(separator: ", ")) across the gated widths — a tier no live row resolves to is not a tier (P2.2)")
        }
        print(String(
            format: "UIProbeGeometry: sidebar UX seam materialized %d live row cells (%d defect-corpus rows per leg) and measured %d labels across 220/280/320pt in Aqua and Dark Aqua; %d labels currently elide by drawable-width measurement; every row paints a zero perimeter, no shadow and no fill at rest, and no sidebar line exceeds %.1fpt with no nested boundary anywhere in the subtree; every card row draws its name on a band of its own between the meta band and the detail band, gives a childless row's name the whole text column, and carries the recorded sacrifice ladder (project < branch < meta < name < state == elapsed == required) as live compression resistances; %d interaction-ladder assertions held per appearance (resting < selected < hover < route-active by measured emphasis, hover outranking selection, a hairline focus ring distinct from selection, and nothing left lit after an exit, a deactivation, a scroll or a full rebuild); %d slim-variant parity assertions held at 220/280/320pt in both appearances; %d measured-fit tier assertions held (three tiers by measured need with no width literal, monotone, each sacrifice real, the name and the state never sacrificed, and every dropped column relocated to the accessibility label); zero-size host rejected with a named error",
            totalCells, rows.count, totalLabels, totalTruncated, LineWidth.hairline,
            ladderAssertions, slimParityAssertions, tierAssertions
        ))
        print("UIProbeGeometry: unconfirmed rows held \(unconfirmedAssertions) live status/frozen-clock assertions at 220/280/320pt in both appearances")
        print("UIProbeGeometry: elapsed formatter table and fixed sidebar/tile column held in \(elapsedAssertions) live assertions")
        print("UIProbeGeometry: live rename editor held \(renameAssertions) body/control/modifier/active-editor/trailing-click/Return/Escape/blur/empty assertions at 220/280/320pt in both appearances")
        print("UIProbeGeometry: filter band held \(filterBandAssertions) production-path scope/search/accessibility assertions at 220/280/320pt, including visible-disabled management and active-scope restoration")
        print("UIProbeGeometry: bulk bar held \(bulkAssertions) production-path scope/search targeting, host-owned confirmation, reentrant idempotence, later repeatability, and 220/280/320 control geometry assertions")
        print("UIProbeGeometry: accessibility/motion sweep held \(accessibilityMotionAssertions) live AX hierarchy, hidden-fact relocation, single status ownership, custom-menu/bulk/shelf/footer semantics, Reduce Motion, Increase Contrast, P6.5 remainder, and resize-divider assertions at 220/280/320pt in Aqua and Dark Aqua")
    }

    /// P5.2 production filter-band gate. It materializes the real ChoiceButton
    /// panel and drives its keyboard, accessibility, and rendered-item paths;
    /// search goes through the live field delegate and compares exact row identity.
    private static func checkSidebarFilterBand(rows: [AgentInboxRow], probeHeight: CGFloat) throws -> Int {
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        guard let longestProject = rows.compactMap(\.projectName).max(by: { $0.count < $1.count }) else {
            throw fail("sidebar-ux-check.filter-band: corpus has no project-name width witness")
        }
        var assertions = 0
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(220), 280, 320] {
                let label = "sidebar-ux-check.filter-band@\(Int(width))pt.\(appearanceName.rawValue)"
                let probe = try makeSidebarProbeHost(width: width, height: probeHeight, appearanceName: appearanceName)
                probe.inbox.reload(rows: rows)
                probe.inbox.layoutForQA()
                probe.host.layoutSubtreeIfNeeded()
                probe.window.orderFront(nil)
                defer { probe.inbox.dismissScopePopoverForQA(); probe.window.orderOut(nil) }

                let scopeButton = probe.inbox.scopeButtonForQA
                let searchField = probe.inbox.searchFieldViewForQA
                let scopePopup = firstDescendant(NSPopUpButton.self, in: scopeButton)
                let visibleStockPopup = firstDescendant(NSPopUpButton.self, in: probe.inbox).flatMap {
                    $0.isHiddenOrHasHiddenAncestor ? nil : $0
                }
                let stockSearch = firstDescendant(NSSearchField.self, in: probe.inbox)
                guard scopePopup == nil, visibleStockPopup == nil, stockSearch == nil,
                      !searchField.isBordered, !searchField.drawsBackground,
                      searchField.focusRingType == .none else {
                    throw fail("\(label): visible stock popup/search chrome remains in the live filter band")
                }
                guard abs(probe.inbox.scopeControlWidthForQA - 124) < 0.5,
                      probe.inbox.searchFieldFrameForQA.width > 0,
                      probe.inbox.searchFieldFrameForQA.minX > probe.inbox.scopeControlWidthForQA else {
                    throw fail("\(label): fixed trigger/search sibling geometry escaped the 124pt band contract")
                }
                let acceptedSearchFocus = probe.window.makeFirstResponder(searchField)
                let searchHasFocus = probe.window.firstResponder === searchField || searchField.currentEditor() != nil
                guard scopeButton.accessibilityLabel() == "Agent scope",
                      searchField.accessibilityLabel() == "Search agents",
                      searchField.accessibilityRole() == .textField,
                      acceptedSearchFocus, searchHasFocus else {
                    throw fail("\(label): filter controls lost invariant accessibility labels or keyboard focus")
                }

                // Return opens the same production panel as mouseDown. Its frame must
                // remain trigger-owned even with the longest project title rendered.
                guard let returnKey = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: probe.window.windowNumber, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36
                ), probe.window.makeFirstResponder(scopeButton) else {
                    throw fail("\(label): could not materialize the scope keyboard path")
                }
                scopeButton.keyDown(with: returnKey)
                let keyboardItems = probe.inbox.scopePopoverItemsForQA
                guard probe.inbox.isScopePopoverPresentedForQA,
                      abs((probe.inbox.scopePopoverWidthForQA ?? -1) - probe.inbox.scopeControlWidthForQA) < 0.5,
                      keyboardItems.contains(where: {
                          $0.id == InboxScope.project(longestProject).storageValue && $0.title == longestProject
                      }) else {
                    throw fail("\(label): production keyboard popover was not 124pt or omitted the longest project name")
                }
                probe.inbox.dismissScopePopoverForQA()

                // VoiceOver opens that same panel. Read management rows and their
                // separator from the rendered ChoiceListView, then activate Create
                // through its rendered ChoiceItem and prove scope restoration.
                probe.inbox.setWorkspaceManagement(canRename: false, canDelete: false)
                var managementPicked: [String] = []
                probe.inbox.onWorkspaceManagementAction = { managementPicked.append($0.title) }
                guard scopeButton.accessibilityPerformPress(), probe.inbox.isScopePopoverPresentedForQA else {
                    throw fail("\(label): accessibility press did not open the scope popover")
                }
                let renderedItems = probe.inbox.scopePopoverItemsForQA
                let renderedManagement = renderedItems.filter { $0.id.hasPrefix("management:") }
                guard renderedManagement.map(\.title) == ["New Workspace…", "Rename Workspace…", "Delete Workspace…"],
                      renderedManagement.map(\.enabled) == [true, false, false],
                      renderedItems.contains(where: { $0.id == "management-separator" && !$0.enabled }) else {
                    throw fail("\(label): rendered management section lost visible-disabled rows or separator")
                }
                let scopeBeforeManagement = probe.inbox.selectedScopeTitleForQA
                guard probe.inbox.pickPresentedScopeItemForQA(id: "management:New Workspace…"),
                      managementPicked == ["New Workspace…"],
                      probe.inbox.selectedScopeTitleForQA == scopeBeforeManagement else {
                    throw fail("\(label): rendered management action replaced the active scope")
                }

                // Scope selection clears an existing selection through the live
                // ChoiceButton list-selection callback.
                guard let first = rows.first,
                      probe.inbox.selectRowForQA(id: first.id),
                      probe.inbox.selectedRowCountForQA == 1 else {
                    throw fail("\(label): live selection witness did not materialize")
                }
                let scopes = InboxScope.entries(for: rows)
                guard let alternate = scopes.first(where: { $0 != .all }),
                      probe.inbox.pickScopeForQA(alternate),
                      probe.inbox.selectedRowCountForQA == 0,
                      scopeButton.accessibilityValue() as? String == alternate.title else {
                    throw fail("\(label): production scope selection did not clear selection or update accessibility value")
                }

                // Search narrows the already-frozen row sequence; it may not rank it.
                let beforeSearch = probe.inbox.rowIdsForQA
                guard let searchTargetID = beforeSearch.first,
                      let searchTarget = rowsByID[searchTargetID],
                      probe.inbox.selectRowForQA(id: searchTargetID) else {
                    throw fail("\(label): scoped search fixture has no visible row")
                }
                let query = searchTarget.title
                let expectedSearchOrder = beforeSearch.filter { id in
                    guard let row = rowsByID[id] else { return false }
                    return [row.title, row.projectName, row.workspaceName, row.model, row.branch]
                        .compactMap { $0 }
                        .contains { $0.localizedCaseInsensitiveContains(query) }
                }
                probe.inbox.setSearchForQA(query)
                probe.inbox.layoutForQA()
                guard !expectedSearchOrder.isEmpty,
                      probe.inbox.rowIdsForQA == expectedSearchOrder,
                      probe.inbox.selectedRowCountForQA == 0 else {
                    throw fail("\(label): search reordered results or retained a hidden bulk selection")
                }

                guard let filteredID = expectedSearchOrder.first,
                      probe.inbox.selectRowForQA(id: filteredID) else {
                    throw fail("\(label): filtered selection witness did not materialize")
                }
                probe.inbox.setSearchForQA("__no_such_agent__")
                probe.inbox.layoutForQA()
                guard probe.inbox.searchResultCountForQA == 0,
                      probe.inbox.selectedRowCountForQA == 0,
                      probe.inbox.isEmptyMessageVisibleForQA,
                      probe.inbox.emptyMessageForQA.contains(alternate.title),
                      probe.inbox.emptyMessageForQA.contains("__no_such_agent__") else {
                    throw fail("\(label): no-result search did not clear selection and name its active scope")
                }
                assertions += 15
            }
        }
        return assertions
    }

    /// P5.3 production bulk-action gate. The probe keeps scope and search active
    /// while selecting, then drives the rendered ChoiceButton exactly once. The
    /// callback is also re-entered to prove only a true duplicate activation is
    /// coalesced; a later activation must still reach the host.
    private static func checkSidebarBulkActionBar(rows: [AgentInboxRow], probeHeight: CGFloat) throws -> Int {
        let deletableRows = rows.filter { InboxBulkAction.delete.isAvailable(for: $0) }
        let grouped = Dictionary(grouping: deletableRows, by: { $0.projectName ?? "" })
        guard let (project, projectRows) = grouped.first(where: { !$0.key.isEmpty && $0.value.count >= 2 }) else {
            throw fail("sidebar-ux-check.bulk: corpus has no two-row deletable project witness")
        }
        var assertions = 0
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for width in [CGFloat(220), 280, 320] {
                let label = "sidebar-ux-check.bulk@\(Int(width))pt.\(appearanceName.rawValue)"
                let probe = try makeSidebarProbeHost(
                    width: width, height: probeHeight, appearanceName: appearanceName,
                    framePinnedInbox: true)
                probe.inbox.onBulkAction = { _, _ in }
                probe.inbox.wiredBulkActions = Set(InboxBulkAction.allCases)
                probe.inbox.reload(rows: rows)
                probe.inbox.layoutForQA()
                probe.host.layoutSubtreeIfNeeded()
                probe.window.orderFront(nil)
                defer { probe.inbox.dismissScopePopoverForQA(); probe.window.orderOut(nil) }

                guard probe.inbox.pickScopeForQA(.project(project)) else {
                    throw fail("\(label): active project scope could not be selected")
                }
                let query = project
                probe.inbox.setSearchForQA(query)
                probe.inbox.layoutForQA()
                let visible = probe.inbox.rowIdsForQA
                let expected = projectRows.map(\.id).filter { visible.contains($0) }
                guard expected.count >= 2,
                      probe.inbox.selectRowsForQA(ids: Array(expected.prefix(2))) else {
                    throw fail("\(label): active scope/search did not expose two selectable rows")
                }
                probe.host.layoutSubtreeIfNeeded()
                // Showing the conditional overlay changes the content view's fitting
                // size. Reassert the requested shipping viewport after that transition
                // before reading any frame; otherwise AppKit silently measures 280.
                let requestedSize = NSSize(width: width, height: probeHeight)
                probe.window.contentMinSize = .zero
                probe.window.contentMaxSize = requestedSize
                probe.window.minSize = .zero
                probe.window.maxSize = requestedSize
                probe.window.setContentSize(requestedSize)
                probe.host.frame = NSRect(origin: .zero, size: requestedSize)
                probe.host.layoutSubtreeIfNeeded()
                // AppKit may still enlarge an offscreen content window to its fitting
                // size. The split view owns the inbox lane in production, so pin the
                // full production inbox itself after materialization and then lay out
                // its real filter/list/bar subtree at the requested width.
                probe.inbox.autoresizingMask = []
                probe.inbox.frame = NSRect(origin: .zero, size: requestedSize)
                probe.inbox.layoutForQA()
                let barFrame = probe.inbox.bulkBarFrameForQA
                let countFrame = probe.inbox.bulkCountFrameForQA
                let actionFrame = probe.inbox.bulkActionTriggerFrameForQA
                guard abs(probe.inbox.bounds.width - width) < 0.5,
                      probe.inbox.isBulkBarVisibleForQA,
                      probe.inbox.bulkSelectionTextForQA == "2 selected",
                      probe.inbox.bounds.contains(barFrame),
                      probe.inbox.bounds.contains(countFrame),
                      probe.inbox.bounds.contains(actionFrame),
                      barFrame.maxY <= probe.inbox.searchFieldFrameForQA.minY + 0.5,
                      countFrame.maxX <= actionFrame.minX + 0.5,
                      probe.inbox.bulkCountDrawsWithoutTruncationForQA,
                      probe.inbox.bulkActionTitleDrawsWithoutTruncationForQA else {
                    throw fail("\(label): rendered count/action geometry escaped, overlapped, or truncated in the exact \(Int(width))pt inbox (window=\(probe.window.contentView?.bounds ?? .zero), host=\(probe.host.bounds), inbox=\(probe.inbox.bounds), bar=\(barFrame), count=\(countFrame), action=\(actionFrame), search=\(probe.inbox.searchFieldFrameForQA), countDraws=\(probe.inbox.bulkCountDrawsWithoutTruncationForQA), actionDraws=\(probe.inbox.bulkActionTitleDrawsWithoutTruncationForQA))")
                }
                let offered = probe.inbox.bulkActionTitlesForQA
                guard offered.contains(InboxBulkAction.delete.title),
                      !offered.contains(where: { $0.hasPrefix("Confirm ") }),
                      probe.inbox.bulkActionTriggerTitleForQA == InboxBulkActionBar.menuTitle,
                      probe.inbox.bulkActionTriggerAccessibilityValueForQA == InboxBulkActionBar.menuTitle else {
                    throw fail("\(label): rendered bar did not offer Delete or leaked selected/confirmation state into its trigger")
                }
                let action = InboxBulkAction.delete

                var callbackCount = 0
                var callbackIDs: [[UUID]] = []
                var reentered = false
                var confirmationAllowsAction = false
                var performedCount = 0
                var triggerSnapshots: [(String, String?)] = []
                probe.inbox.onBulkAction = { receivedAction, ids in
                    callbackCount += 1
                    callbackIDs.append(ids)
                    triggerSnapshots.append((
                        probe.inbox.bulkActionTriggerTitleForQA,
                        probe.inbox.bulkActionTriggerAccessibilityValueForQA))
                    if !reentered {
                        reentered = true
                        _ = probe.inbox.pickBulkActionForQA(receivedAction)
                    }
                    if confirmationAllowsAction { performedCount += 1 }
                }
                // First host confirmation declines: one synchronous duplicate is
                // coalesced, no action performs, and the trigger stays neutral while
                // the host callback owns its modal decision.
                guard probe.inbox.pickBulkActionForQA(action), callbackCount == 1,
                      callbackIDs == [Array(expected.prefix(2))], performedCount == 0,
                      triggerSnapshots.allSatisfy({ $0.0 == InboxBulkActionBar.menuTitle && $0.1 == InboxBulkActionBar.menuTitle }),
                      probe.inbox.bulkActionTriggerTitleForQA == InboxBulkActionBar.menuTitle,
                      probe.inbox.bulkActionTriggerAccessibilityValueForQA == InboxBulkActionBar.menuTitle else {
                    throw fail("\(label): canceled destructive dispatch retargeted, double-fired, performed, or changed trigger state")
                }
                // A later retry after cancellation is legitimate and reaches the host.
                confirmationAllowsAction = true
                guard probe.inbox.pickBulkActionForQA(action), callbackCount == 2,
                      performedCount == 1 else {
                    throw fail("\(label): later confirmed retry was suppressed")
                }
                assertions += 7
            }
        }
        return assertions
    }

    // MARK: - P6.6 — the live accessibility/motion sweep

    /// Walk the AX tree that the production inbox exposes. This intentionally
    /// follows `accessibilityChildren()` rather than `subviews`: a visually hidden
    /// measured-fit label can still exist in the view tree while being absent from
    /// the reachable accessibility tree, and that distinction is the defect this
    /// ticket gates.
    private static func accessibilityDescendants(of root: NSView) -> [NSView] {
        var result: [NSView] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ view: NSView) {
            guard seen.insert(ObjectIdentifier(view)).inserted else { return }
            result.append(view)
            for child in view.accessibilityChildren() ?? [] {
                if let child = child as? NSView { visit(child) }
            }
        }
        visit(root)
        return result
    }

    private static func legacyAccessibilityValue(
        _ object: Any, _ attribute: NSAccessibility.Attribute
    ) -> Any? {
        (object as? NSObject)?.accessibilityAttributeValue(attribute)
    }

    private static func accessibilityChildren(of object: Any) -> [Any] {
        if let view = object as? NSView { return view.accessibilityChildren() ?? [] }
        if let element = object as? NSAccessibilityElement,
           let children = element.accessibilityChildren() {
            return children
        }
        if let children = legacyAccessibilityValue(object, .children) as? [Any] {
            return children
        }
        return []
    }

    private static func accessibilityRole(of object: Any) -> NSAccessibility.Role? {
        if let view = object as? NSView { return view.accessibilityRole() }
        if let role = (object as? NSAccessibilityElement)?.accessibilityRole() { return role }
        return legacyAccessibilityValue(object, .role) as? NSAccessibility.Role
    }

    private static func accessibilityLabel(of object: Any) -> String? {
        if let view = object as? NSView { return view.accessibilityLabel() }
        if let label = (object as? NSAccessibilityElement)?.accessibilityLabel() { return label }
        return (legacyAccessibilityValue(object, .description)
            ?? legacyAccessibilityValue(object, .title)) as? String
    }

    private static func accessibilityIdentifier(of object: Any) -> String? {
        if let view = object as? NSView { return view.accessibilityIdentifier() }
        if let identifier = (object as? NSAccessibilityElement)?.accessibilityIdentifier() {
            return identifier
        }
        return legacyAccessibilityValue(object, .identifier) as? String
    }

    private static func accessibilityIndex(of object: Any) -> Int? {
        if let value = legacyAccessibilityValue(object, .index) as? Int { return value }
        if let value = legacyAccessibilityValue(object, .index) as? NSNumber { return value.intValue }
        return nil
    }

    private static func accessibilityValueString(of object: Any) -> String {
        let value: Any?
        if let view = object as? NSView {
            value = view.accessibilityValue()
        } else if let element = object as? NSAccessibilityElement {
            value = element.accessibilityValue()
        } else {
            value = legacyAccessibilityValue(object, .value)
        }
        if let value = value as? String { return value }
        return value.map { String(describing: $0) } ?? ""
    }

    /// Traverse the live AX provider objects, including AppKit's virtual table
    /// children. The object identity guard prevents a native row provider from
    /// being visited twice when it also appears through a materialized view.
    private static func accessibilityObjects(from root: Any) -> [Any] {
        var result: [Any] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: Any) {
            let identity = ObjectIdentifier(object as AnyObject)
            guard seen.insert(identity).inserted else { return }
            result.append(object)
            for child in accessibilityChildren(of: object) { visit(child) }
        }
        visit(root)
        return result
    }

    private static func axNode(
        _ views: [NSView], identifier: String
    ) -> NSView? {
        views.first { $0.accessibilityIdentifier() == identifier }
    }

    private static func checkSidebarAccessibilityMotion(
        rows: [AgentInboxRow], probeHeight: CGFloat
    ) throws -> Int {
        let widths: [CGFloat] = [220, 280, 320]
        let unconfirmedSource = rows.first { $0.state == .working && $0.elapsed != nil }
            ?? rows.first!
        let unconfirmedIDs = LabFixtures.sidebarUnobservedAgentIds()
        let axRows = rows.map { row in
            if unconfirmedIDs.contains(row.id) || row.id == unconfirmedSource.id {
                return row.withUnconfirmed(true, elapsed: row.elapsed ?? 4_200)
            }
            return row
        }
        guard let fanoutParentID = rows.first(where: { candidate in
            rows.contains { $0.parentId == candidate.id }
        })?.id else {
            throw fail("sidebar-ux-check.accessibility: no P6.5 fan-out parent in the live corpus")
        }
        var assertions = 0

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for width in widths {
                // A deliberately small viewport is important here. The table must
                // have enough content to scroll, but this proof must not turn the
                // host into a full-list materialization fixture.
                let label = "sidebar-ux-check.accessibility@\(Int(width))pt.\(appearanceName.rawValue)"
                let probe = try makeSidebarProbeHost(
                    width: width,
                    height: min(probeHeight, CGFloat(190)),
                    appearanceName: appearanceName)
                probe.inbox.prefersReducedMotion = { false }
                probe.inbox.prefersIncreasedContrast = { false }
                probe.inbox.toggleShelf()
                probe.inbox.reload(rows: axRows)
                probe.inbox.layoutViewportForQA()
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.layoutViewportForQA()

                // Inspect the real P6.5 remainder button before pressing it. The
                // press is deliberately after this AX assertion because it removes
                // that affordance from the live table.
                guard probe.inbox.scrollToFanoutRemainderForQA(parentId: fanoutParentID),
                      let remainder = probe.inbox.fanoutRemainderRowsForQA.first(where: {
                          $0.parentId == fanoutParentID
                      }) else {
                    throw fail("\(label): P6.5 remainder did not materialize in the constrained viewport")
                }
                let beforeRemainderAX = accessibilityObjects(from: probe.inbox)
                let remainderLabel = "Show \(remainder.accessibilityTitle)"
                guard let remainderButton = beforeRemainderAX.first(where: {
                    accessibilityRole(of: $0) == .button
                        && accessibilityLabel(of: $0) == remainderLabel
                }),
                accessibilityValueString(of: remainderButton) == remainder.accessibilityTitle else {
                    throw fail("\(label): P6.5 remainder button was not a reachable live AX child before expansion")
                }
                assertions += 2
                guard probe.inbox.clickFanoutRemainderForQA(parentId: fanoutParentID) else {
                    throw fail("\(label): P6.5 remainder was not operable through its live button")
                }
                probe.inbox.layoutViewportForQA()
                probe.inbox.scrollToTopForQA()

                let rootAX = accessibilityDescendants(of: probe.inbox)
                guard probe.inbox.accessibilityRole() == .group,
                      probe.inbox.accessibilityLabel() == "Agent inbox",
                      probe.inbox.accessibilityChildren()?.contains(where: {
                          ($0 as? NSView)?.accessibilityIdentifier() == "ContinuumAgentInboxScope"
                      }) == true,
                      probe.inbox.accessibilityChildren()?.contains(where: {
                          ($0 as? NSView)?.accessibilityIdentifier() == "ContinuumAgentInboxSearch"
                      }) == true,
                      probe.inbox.accessibilityChildren()?.contains(where: {
                          ($0 as? NSView)?.accessibilityIdentifier() == "ContinuumAgentInboxList"
                      }) == true else {
                    throw fail("\(label): inbox root lost its group hierarchy or fixed filter/list children")
                }
                guard let scope = axNode(rootAX, identifier: "ContinuumAgentInboxScope"),
                      scope.accessibilityRole() == .popUpButton,
                      scope.accessibilityLabel() == "Agent scope",
                      !accessibilityValueString(of: scope).isEmpty,
                      let search = axNode(rootAX, identifier: "ContinuumAgentInboxSearch"),
                      search.accessibilityRole() == .textField,
                      search.accessibilityLabel() == "Search agents",
                      let list = axNode(rootAX, identifier: "ContinuumAgentInboxList"),
                      list.accessibilityRole() == .list else {
                    throw fail("\(label): scope/search/list role, label, or value is incomplete")
                }
                let displayedRows = probe.inbox.rowIdsForQA.compactMap { id in
                    axRows.first(where: { $0.id == id })
                }
                guard !displayedRows.isEmpty,
                      accessibilityValueString(of: list) == "\(displayedRows.count) agents" else {
                    throw fail("\(label): live list value did not match its displayed agent rows")
                }
                assertions += 6

                // Read the native table provider, not a copied list of cells. A
                // constrained viewport must leave at least one displayed row
                // materialized and at least one displayed row offscreen, while
                // every displayed row remains reachable through native AX children.
                let nativeTableChildren = probe.inbox.tableAccessibilityChildrenForQA
                let nativeRows = nativeTableChildren.filter {
                    accessibilityRole(of: $0) == .row
                }
                let viewportCells = probe.inbox.qaMaterializedRowCells
                let visibleIDs = Set(probe.inbox.visibleAgentIdsForQA)
                guard viewportCells.count > 0,
                      viewportCells.count < displayedRows.count,
                      nativeRows.count == probe.inbox.tableRowCountForQA,
                      let offscreen = displayedRows.reversed().first(where: {
                          !visibleIDs.contains($0.id)
                      }) else {
                    throw fail("\(label): constrained table did not leave a real offscreen row beside materialized cells or native AX rows (materialized=\(viewportCells.count), displayed=\(displayedRows.count), native=\(nativeRows.count), table=\(probe.inbox.tableRowCountForQA), visible=\(visibleIDs.count))")
                }
                let nativeIndexes = Set(nativeRows.compactMap(accessibilityIndex(of:)))
                guard nativeIndexes == Set(0..<probe.inbox.tableRowCountForQA) else {
                    throw fail("\(label): NSTableView native AX row providers lost virtual indexes (indexes=\(nativeIndexes.sorted()), table=\(probe.inbox.tableRowCountForQA))")
                }
                for row in displayedRows {
                    guard let tableRow = probe.inbox.tableRowIndexForQA(id: row.id),
                          nativeIndexes.contains(tableRow) else {
                        throw fail("\(label): displayed row '\(row.displayTitle)' was absent from the native virtual AX index hierarchy")
                    }
                }
                guard let offscreenTableRow = probe.inbox.tableRowIndexForQA(id: offscreen.id),
                      nativeRows.contains(where: { accessibilityIndex(of: $0) == offscreenTableRow }) else {
                    throw fail("\(label): offscreen row '\(offscreen.displayTitle)' was absent from NSTableView's native virtual AX children")
                }
                assertions += 5

                // Virtual reachability was proven above while the viewport stayed
                // constrained. Ask AppKit for the remaining row views only now,
                // for a separate exact-ownership audit, and require both production
                // variants so card-only coverage cannot make slim duplication pass.
                probe.inbox.layoutForQA()
                let materializedCells = probe.inbox.qaMaterializedRowCells
                let materializedVariants = materializedCells.compactMap { cell in
                    displayedRows.first(where: { $0.id == cell.qaAgentID })?.variant
                }
                guard materializedVariants.contains(.card),
                      materializedVariants.contains(.slim) else {
                    throw fail("\(label): exact AX ownership did not inspect both card and slim rows (cells=\(materializedCells.count), rows=\(displayedRows.count), variants=\(materializedVariants))")
                }
                assertions += 2

                // Detailed child ownership is asserted for the materialized card
                // and slim cells after the independent virtual-row proof above.
                for cell in materializedCells {
                    guard let id = cell.qaAgentID,
                          let row = displayedRows.first(where: { $0.id == id }),
                          cell.accessibilityRole() == .row,
                          let cellLabel = cell.accessibilityLabel(),
                          cellLabel.contains(row.displayTitle),
                          accessibilityValueString(of: cell).isEmpty else {
                        throw fail("\(label): materialized row lost its row/name semantics or grew a duplicate status value")
                    }
                    let descendants = accessibilityObjects(from: cell)
                    let identifiers = Set(descendants.compactMap(accessibilityIdentifier(of:)))
                    guard !identifiers.contains("ContinuumAgentInboxTitleLabel"),
                          !identifiers.contains("ContinuumAgentInboxElapsedLabel"),
                          !identifiers.contains("ContinuumAgentInboxTimeLabel") else {
                        throw fail("\(label): row \(row.displayTitle) exposes a duplicate name or ticking duration child")
                    }
                    guard let geometry = probe.inbox.qaRowGeometriesForQA.first(where: {
                        $0.agentID == row.id
                    }) else {
                        throw fail("\(label): missing live geometry for \(row.displayTitle)")
                    }
                    let byElement = Dictionary(uniqueKeysWithValues: geometry.labels.map {
                        ($0.element, $0)
                    })
                    if let project = row.projectName, !project.isEmpty {
                        if row.variant == .slim {
                            guard cellLabel.contains("Project \(project)"),
                                  !identifiers.contains("ContinuumAgentInboxProjectLabel") else {
                                throw fail("\(label): slim project fact for \(row.displayTitle) was not owned exactly once by the row")
                            }
                        } else if byElement["project"]?.isHidden == true {
                            guard cellLabel.contains("Project \(project)"),
                                  !identifiers.contains("ContinuumAgentInboxProjectLabel") else {
                                throw fail("\(label): hidden project fact for \(row.displayTitle) was not relocated exactly once to its row owner")
                            }
                        } else {
                            guard !cellLabel.contains("Project \(project)"),
                                  identifiers.contains("ContinuumAgentInboxProjectLabel") else {
                                throw fail("\(label): visible project fact for \(row.displayTitle) was duplicated or lost its child owner")
                            }
                        }
                    }
                    if let branch = row.branch, !branch.isEmpty {
                        let branchText = AgentInboxCellView.branchText(branch: branch)
                        if byElement["branch"]?.isHidden == true {
                            guard cellLabel.contains("Branch \(branchText)"),
                                  !identifiers.contains("ContinuumAgentInboxBranchLabel") else {
                                throw fail("\(label): hidden branch fact for \(row.displayTitle) was not relocated exactly once to its row owner")
                            }
                        } else {
                            guard !cellLabel.contains("Branch \(branchText)"),
                                  identifiers.contains("ContinuumAgentInboxBranchLabel") else {
                                throw fail("\(label): visible branch fact for \(row.displayTitle) was duplicated or lost its child owner")
                            }
                        }
                    }
                    if row.variant == .slim {
                        let slimPlacement = row.isIsolated
                            ? "isolated"
                            : (row.branch?.isEmpty == false ? "shared" : nil)
                        if let slimPlacement {
                            guard cellLabel.contains(slimPlacement),
                                  !identifiers.contains("ContinuumAgentInboxMetaLabel") else {
                                throw fail("\(label): slim placement fact for \(row.displayTitle) was not owned exactly once by the row")
                            }
                        }
                    } else if let meta = byElement["meta"], !meta.text.isEmpty {
                        if meta.isHidden {
                            guard cellLabel.contains("Details \(meta.text)"),
                                  !identifiers.contains("ContinuumAgentInboxMetaLabel") else {
                                throw fail("\(label): hidden meta fact for \(row.displayTitle) was not relocated exactly once to its row owner")
                            }
                        } else {
                            guard !cellLabel.contains("Details \(meta.text)"),
                                  identifiers.contains("ContinuumAgentInboxMetaLabel") else {
                                throw fail("\(label): visible meta fact for \(row.displayTitle) was duplicated or lost its child owner")
                            }
                        }
                    }
                    if let model = row.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !model.isEmpty {
                        if row.variant == .slim {
                            guard cellLabel.contains("Model \(model)"),
                                  !identifiers.contains("ContinuumAgentInboxProviderLabel") else {
                                throw fail("\(label): slim model fact for \(row.displayTitle) was not owned exactly once by the row")
                            }
                        } else if let provider = byElement["provider"], provider.isHidden {
                            guard cellLabel.contains("Model \(model)"),
                                  !identifiers.contains("ContinuumAgentInboxProviderLabel") else {
                                throw fail("\(label): hidden model fact for \(row.displayTitle) was not relocated exactly once to its row owner")
                            }
                        } else {
                            guard !cellLabel.contains("Model \(model)"),
                                  identifiers.contains("ContinuumAgentInboxProviderLabel"),
                                  byElement["provider"]?.accessibilityLabel == model else {
                                throw fail("\(label): visible model fact for \(row.displayTitle) was duplicated or lost its provider child owner")
                            }
                        }
                    }
                    if let elapsed = AgentInboxCellView.elapsedText(row.elapsed) {
                        guard cellLabel.contains(elapsed) else {
                            throw fail("\(label): exact duration fact for \(row.displayTitle) is absent from its row owner")
                        }
                    }
                    let statusOwners = descendants.filter { object in
                        let spoken = "\(accessibilityLabel(of: object) ?? "") \(accessibilityValueString(of: object))"
                        return (accessibilityRole(of: object) == .staticText
                            || accessibilityRole(of: object) == .image)
                            && spoken.contains("Status")
                    }
                    let owner = cell.accessibilityStatusOwner
                    let ownerWords = "\(accessibilityLabel(of: owner) ?? "") \(accessibilityValueString(of: owner))"
                    let expectedStatus = row.isUnconfirmed ? "Unconfirmed" : (row.label ?? "Ready")
                    guard statusOwners.count == 1,
                          statusOwners.first.map({ ObjectIdentifier($0 as AnyObject) })
                              == ObjectIdentifier(owner),
                          (accessibilityRole(of: owner) == .staticText
                              || accessibilityRole(of: owner) == .image),
                          ownerWords.contains("Status"),
                          ownerWords.contains(expectedStatus),
                          !row.isUnconfirmed || ownerWords.contains("no live agent snapshot") else {
                        throw fail("\(label): row \(row.displayTitle) did not have exactly one reachable semantic status owner with its current explanation")
                    }
                    assertions += 6
                }

                // The custom row menu is a ChoiceListView/list of enabled rows, not
                // stock NSMenu chrome. Require a real child before applying the
                // universal child assertion; an empty allSatisfy would be vacuous.
                probe.inbox.onRevealRow = { _ in }
                probe.inbox.onRowAction = { _, _ in }
                probe.inbox.wiredRowActions = Set(InboxRowAction.allCases)
                guard let menuTarget = displayedRows.first(where: { $0.variant == .card }),
                      probe.inbox.openRowMenuForQA(clickedRowId: menuTarget.id),
                      probe.inbox.isRowMenuWiredForQA,
                      probe.inbox.rowMenuAccessibilityRoleForQA == .list,
                      probe.inbox.rowMenuAccessibilityLabelForQA == "Agent actions",
                      probe.inbox.rowMenuTitlesForQA.contains("Open in Tile") else {
                    throw fail("\(label): custom context menu lost its live list/action surface")
                }
                let menuChildren = probe.inbox.rowMenuAccessibilityChildrenForQA
                guard !menuChildren.isEmpty,
                      menuChildren.allSatisfy({
                          accessibilityRole(of: $0) == .row
                              && accessibilityLabel(of: $0) != nil
                      }) else {
                    throw fail("\(label): custom context menu exposed no real AX row child or a child without a label")
                }
                assertions += 7
                _ = probe.inbox.openRowMenuForQA(clickedRowId: nil)

                // Bulk actions are one group with a neutral, enabled pull-down;
                // the count and action are reachable children, not painted-only text.
                let bulkRows = displayedRows.filter {
                    InboxBulkAction.delete.isAvailable(for: $0)
                }
                guard bulkRows.count >= 2 else {
                    throw fail("\(label): no bulk-action witness rows")
                }
                probe.inbox.onBulkAction = { _, _ in }
                probe.inbox.wiredBulkActions = Set(InboxBulkAction.allCases)
                guard probe.inbox.selectRowsForQA(ids: Array(bulkRows.prefix(2).map(\.id))) else {
                    throw fail("\(label): bulk accessibility witness could not select two rows")
                }
                probe.inbox.layoutForQA()
                let bulkAX = accessibilityObjects(from: probe.inbox)
                guard let bulk = bulkAX.first(where: {
                    accessibilityIdentifier(of: $0) == "ContinuumAgentInboxBulkBar"
                }),
                      accessibilityRole(of: bulk) == .group,
                      accessibilityLabel(of: bulk) == "Bulk actions",
                      accessibilityValueString(of: bulk) == "2 selected" else {
                    throw fail("\(label): bulk card lost group/value semantics")
                }
                let bulkChildren = accessibilityChildren(of: bulk)
                guard !bulkChildren.isEmpty,
                      bulkChildren.contains(where: {
                          accessibilityRole(of: $0) == .popUpButton
                              && accessibilityLabel(of: $0) == InboxBulkActionBar.menuTitle
                      }) else {
                    throw fail("\(label): bulk card exposed no real action control")
                }
                assertions += 6

                // Exercise the real toast, its real Undo button, and the real
                // callback. A rendered message without a reversible backing store
                // is not an accessibility action.
                let undoRows = displayedRows.filter {
                    $0.lifecycle == .active && InboxBulkAction.settle.isAvailable(for: $0)
                }
                guard undoRows.count >= 2 else {
                    throw fail("\(label): no reversible settle rows for the live undo witness")
                }
                let undoIDs = Array(undoRows.prefix(2).map(\.id))
                var undoFacts = Dictionary(uniqueKeysWithValues: undoIDs.map {
                    ($0, InboxLifecycleSnapshot())
                })
                var restoredFacts: [UUID: InboxLifecycleSnapshot]?
                probe.inbox.lifecycleFacts = { undoFacts[$0] }
                probe.inbox.onUndoLifecycle = { restoredFacts = $0 }
                probe.inbox.onBulkAction = { action, ids in
                    guard action == .settle else { return }
                    for id in ids {
                        undoFacts[id] = InboxLifecycleSnapshot(
                            settledOverride: .settled,
                            settledAt: LabFixtures.inboxNow)
                    }
                }
                probe.inbox.wiredBulkActions = [.settle]
                guard probe.inbox.selectRowsForQA(ids: undoIDs) else {
                    throw fail("\(label): undo witness could not select its reversible rows")
                }
                probe.inbox.layoutForQA()
                guard probe.inbox.bulkActionTitlesForQA.contains("Settle"),
                      probe.inbox.pickBulkActionForQA(.settle) else {
                    throw fail("\(label): live settle action did not reach the host path that raises Undo")
                }
                probe.inbox.layoutForQA()
                let undoAX = accessibilityObjects(from: probe.inbox)
                guard let toast = undoAX.first(where: {
                    accessibilityIdentifier(of: $0) == "ContinuumAgentInboxUndoToast"
                }),
                      accessibilityRole(of: toast) == .group,
                      accessibilityLabel(of: toast) == "Undo notification",
                      !accessibilityValueString(of: toast).isEmpty else {
                    throw fail("\(label): live undo toast did not materialize with its group/value hierarchy")
                }
                let toastChildren = accessibilityChildren(of: toast)
                guard toastChildren.count >= 2,
                      toastChildren.contains(where: {
                          accessibilityRole(of: $0) == .staticText
                              && accessibilityIdentifier(of: $0) == "ContinuumAgentInboxUndoMessage"
                      }),
                      toastChildren.contains(where: {
                          accessibilityRole(of: $0) == .button
                              && accessibilityIdentifier(of: $0) == "ContinuumAgentInboxUndoButton"
                              && accessibilityLabel(of: $0) == "Undo"
                      }) else {
                    throw fail("\(label): live undo toast exposed no real message/button child")
                }
                guard probe.inbox.clickUndoForQA(),
                      restoredFacts == Dictionary(uniqueKeysWithValues: undoIDs.map {
                          ($0, InboxLifecycleSnapshot())
                      }),
                      probe.inbox.undoToastTextForQA.isEmpty else {
                    throw fail("\(label): live Undo button did not invoke the restore callback and dismiss the toast")
                }
                assertions += 8
            }
        }

        // Status snapshots are compared at the list boundary. Use a small table
        // with a deliberately offscreen last row, then prove removed/reintroduced
        // ids are silent and a materialized cell is refreshed without a stale word.
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for width in widths {
                let label = "sidebar-ux-check.accessibility.status@\(Int(width))pt.\(appearanceName.rawValue)"
                let statusProbe = try makeSidebarProbeHost(
                    width: width, height: min(probeHeight, CGFloat(190)), appearanceName: appearanceName)
                var owners: [NSView] = []
                var messages: [String] = []
                statusProbe.inbox.accessibilityAnnouncementSink = { owner, message in
                    owners.append(owner)
                    messages.append(message)
                }
                func replacing(
                    _ row: AgentInboxRow,
                    state: InboxState,
                    unconfirmed: Bool = false,
                    elapsed: TimeInterval? = nil
                ) -> AgentInboxRow {
                    AgentInboxRow(
                        id: row.id, title: row.title, projectName: row.projectName,
                        workspaceName: row.workspaceName, state: state, attention: row.attention,
                        lifecycle: row.lifecycle, model: row.model, role: row.role,
                        branch: row.branch, isIsolated: row.isIsolated,
                        elapsed: elapsed ?? row.elapsed, lastActiveAt: row.lastActiveAt,
                        depth: row.depth, createdAt: row.createdAt, parentId: row.parentId,
                        isUnconfirmed: unconfirmed, settlementBlocked: row.settlementBlocked)
                }
                let statusRows = Array(rows.filter {
                    $0.variant == .card && $0.parentId == nil
                }.prefix(6)).map { replacing($0, state: .ready, elapsed: 90) }
                guard statusRows.count >= 4, let offscreenSource = statusRows.last else {
                    throw fail("\(label): constrained status table lacks enough card rows")
                }
                statusProbe.inbox.reload(rows: statusRows)
                statusProbe.inbox.layoutViewportForQA()
                statusProbe.host.layoutSubtreeIfNeeded()
                statusProbe.inbox.layoutViewportForQA()
                guard !statusProbe.inbox.visibleAgentIdsForQA.contains(offscreenSource.id),
                      statusProbe.inbox.qaMaterializedRowCellCount < statusRows.count else {
                    throw fail("\(label): status witness did not keep its transition source offscreen")
                }
                guard messages.isEmpty else {
                    throw fail("\(label): initial status load announced unexpectedly")
                }
                statusProbe.inbox.resetAccessibilityAnnouncementsForQA()
                let transitioned = replacing(
                    offscreenSource, state: .approval, elapsed: 91)
                statusProbe.inbox.apply(
                    rows: statusRows.map { $0.id == transitioned.id ? transitioned : $0 },
                    changed: AgentsBoardChangeSet(added: [], updated: [transitioned.id], removed: []))
                statusProbe.inbox.layoutViewportForQA()
                guard messages.count == 1,
                      messages[0].contains("Needs attention"),
                      !messages[0].contains("91"),
                      owners.count == 1 else {
                    throw fail("\(label): offscreen status transition was not announced exactly once at the row-model boundary")
                }
                statusProbe.inbox.layoutViewportForQA()
                guard messages.count == 1 else {
                    throw fail("\(label): repeated offscreen layout announced the transition twice")
                }
                let ticked = replacing(transitioned, state: .approval, elapsed: 92)
                statusProbe.inbox.apply(
                    rows: statusRows.map { $0.id == ticked.id ? ticked : $0 },
                    changed: AgentsBoardChangeSet(added: [], updated: [ticked.id], removed: []))
                statusProbe.inbox.layoutViewportForQA()
                guard messages.count == 1 else {
                    throw fail("\(label): elapsed-only update announced a second status change")
                }
                guard statusProbe.inbox.scrollToAgentForQA(id: ticked.id),
                      statusProbe.inbox.qaMaterializedRowCells.contains(where: {
                          $0.qaAgentID == ticked.id
                      }),
                      messages.count == 1 else {
                    throw fail("\(label): actually materializing the transitioned offscreen row replayed or lost its one announcement")
                }
                // Remove, then reintroduce the same id with a different state. The
                // prune at the update boundary makes this a new initial observation.
                let withoutSource = statusRows.filter { $0.id != transitioned.id }
                statusProbe.inbox.apply(
                    rows: withoutSource,
                    changed: AgentsBoardChangeSet(added: [], updated: [], removed: [transitioned.id]))
                statusProbe.inbox.apply(
                    rows: withoutSource + [replacing(offscreenSource, state: .failed, elapsed: 93)],
                    changed: AgentsBoardChangeSet(added: [offscreenSource.id], updated: [], removed: []))
                guard messages.count == 1 else {
                    throw fail("\(label): removed/reintroduced status id retained stale announcement state")
                }
                let confirmedVisible = statusRows[0]
                let confirmedTransition = replacing(confirmedVisible, state: .approval, elapsed: 94)
                statusProbe.inbox.apply(
                    rows: statusRows.map { $0.id == confirmedVisible.id ? confirmedTransition : $0 },
                    changed: AgentsBoardChangeSet(added: [], updated: [confirmedVisible.id], removed: []))
                statusProbe.inbox.layoutForQA()
                guard let recycled = statusProbe.inbox.qaMaterializedRowCells.first(where: {
                    $0.qaAgentID == confirmedVisible.id
                }),
                let recycledOwner = recycled.accessibilityStatusOwner as? NSView,
                ("\(recycledOwner.accessibilityLabel() ?? "") \(accessibilityValueString(of: recycledOwner))")
                    .contains("Needs attention") else {
                    throw fail("\(label): recycled row retained stale status-owner wording")
                }
                assertions += 7
            }
        }

        // Shelf and settled-more are separate table rows, so probe each at all
        // shipping widths/themes rather than accepting the agent-row census as a
        // proxy for section chrome.
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for width in widths {
                let label = "sidebar-ux-check.accessibility.sections@\(Int(width))pt.\(appearanceName.rawValue)"
                let shelfProbe = try makeSidebarProbeHost(width: width, height: probeHeight, appearanceName: appearanceName)
                shelfProbe.inbox.clock = { LabFixtures.inboxNow }
                shelfProbe.inbox.reload(rows: LabFixtures.inboxParkedRows())
                shelfProbe.inbox.layoutForQA()
                shelfProbe.host.layoutSubtreeIfNeeded()
                shelfProbe.inbox.layoutForQA()
                let shelfAX = accessibilityObjects(from: shelfProbe.inbox)
                guard let shelfButton = shelfAX.first(where: {
                    accessibilityRole(of: $0) == .button
                        && (accessibilityLabel(of: $0) ?? "").hasPrefix("Expand Snoozed")
                }),
                accessibilityValueString(of: shelfButton).contains("collapsed") else {
                    throw fail("\(label): snoozed shelf header lost collapsed button/value semantics")
                }
                guard shelfProbe.inbox.clickShelfDisclosureForQA() else {
                    throw fail("\(label): shelf header was not operable through its live button")
                }
                shelfProbe.inbox.layoutForQA()
                let expandedShelfAX = accessibilityObjects(from: shelfProbe.inbox)
                guard let expandedShelf = expandedShelfAX.first(where: {
                    accessibilityRole(of: $0) == .button
                        && (accessibilityLabel(of: $0) ?? "").hasPrefix("Collapse Snoozed")
                }),
                accessibilityValueString(of: expandedShelf).contains("expanded") else {
                    throw fail("\(label): snoozed shelf header lost expanded semantics")
                }
                assertions += 4

                let tailProbe = try makeSidebarProbeHost(width: width, height: probeHeight, appearanceName: appearanceName)
                tailProbe.inbox.reload(rows: LabFixtures.inboxPagedRows())
                tailProbe.inbox.layoutForQA()
                tailProbe.host.layoutSubtreeIfNeeded()
                tailProbe.inbox.layoutForQA()
                let tailAX = accessibilityObjects(from: tailProbe.inbox)
                guard let more = tailAX.first(where: {
                    accessibilityRole(of: $0) == .button
                        && (accessibilityLabel(of: $0) ?? "").hasPrefix("Show \(InboxSort.settledPageStep) more")
                }),
                accessibilityValueString(of: more).contains("settled agents hidden") else {
                    throw fail("\(label): settled-more footer lost enabled button/value semantics")
                }
                guard tailProbe.inbox.clickSettledMoreForQA() else {
                    throw fail("\(label): settled-more footer was not operable through its live button")
                }
                tailProbe.inbox.layoutForQA()
                guard !accessibilityObjects(from: tailProbe.inbox).contains(where: {
                    accessibilityRole(of: $0) == .button
                        && (accessibilityLabel(of: $0) ?? "").hasPrefix("Show \(InboxSort.settledPageStep) more")
                }) else {
                    throw fail("\(label): settled-more footer remained in the AX tree after paging")
                }
                assertions += 4
            }
        }

        // Reduce Motion is a production decision, not an assertion that no code
        // calls NSAnimationContext. The variant cue still lands immediately while
        // the optional ghost exists only when the injected setting permits motion.
        let motionRow = rows.first { $0.variant == .card && $0.elapsed != nil } ?? rows.first!
        func parked(_ row: AgentInboxRow) -> AgentInboxRow {
            AgentInboxRow(
                id: row.id, title: row.title, projectName: row.projectName,
                workspaceName: row.workspaceName, state: .ready, attention: row.attention,
                lifecycle: .settled(at: LabFixtures.inboxNow), model: row.model, role: row.role,
                branch: row.branch, isIsolated: row.isIsolated, elapsed: row.elapsed,
                lastActiveAt: row.lastActiveAt, depth: row.depth, createdAt: row.createdAt,
                parentId: row.parentId, isUnconfirmed: row.isUnconfirmed,
                settlementBlocked: row.settlementBlocked)
        }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for width in widths {
                for reduced in [false, true] {
                    let label = "sidebar-ux-check.accessibility.motion@\(Int(width))pt.\(appearanceName.rawValue).reduced=\(reduced)"
                    let probe = try makeSidebarProbeHost(width: width, height: probeHeight, appearanceName: appearanceName)
                    probe.inbox.prefersReducedMotion = { reduced }
                    probe.inbox.reload(rows: [motionRow])
                    probe.inbox.layoutForQA()
                    probe.host.layoutSubtreeIfNeeded()
                    probe.inbox.layoutForQA()
                    probe.inbox.apply(
                        rows: [parked(motionRow)],
                        changed: AgentsBoardChangeSet(added: [], updated: [motionRow.id], removed: []))
                    probe.inbox.layoutForQA()
                    guard probe.inbox.rowVariantsForQA == [.slim],
                          !probe.inbox.glyphsForQA.first!.isEmpty,
                          probe.inbox.titlesForQA.first == motionRow.displayTitle else {
                        throw fail("\(label): semantic card-to-slim cue disappeared during the transition")
                    }
                    if reduced {
                        guard probe.inbox.crossfadingRowCountForQA == 0 else {
                            throw fail("\(label): Reduce Motion left a crossfade ghost in the live tree")
                        }
                    } else {
                        guard probe.inbox.crossfadingRowCountForQA == 1 else {
                            throw fail("\(label): normal motion did not use the production in-place transition")
                        }
                    }
                    assertions += 3
                }
            }
        }

        // Measure the actual painted fills against the actual surrounding panel.
        // No expected paint is computed with AgentInboxCardView.interactionFill.
        func rgba(_ color: CGColor) -> (r: Double, g: Double, b: Double, a: Double)? {
            guard let nsColor = NSColor(cgColor: color),
                  let srgb = nsColor.usingColorSpace(.sRGB) else { return nil }
            return (Double(srgb.redComponent), Double(srgb.greenComponent),
                    Double(srgb.blueComponent), Double(srgb.alphaComponent))
        }
        func composite(
            _ foreground: (r: Double, g: Double, b: Double, a: Double),
            over background: (r: Double, g: Double, b: Double, a: Double)
        ) -> (r: Double, g: Double, b: Double) {
            (
                foreground.r * foreground.a + background.r * (1 - foreground.a),
                foreground.g * foreground.a + background.g * (1 - foreground.a),
                foreground.b * foreground.a + background.b * (1 - foreground.a))
        }
        func luminance(_ color: (r: Double, g: Double, b: Double)) -> Double {
            func linear(_ component: Double) -> Double {
                component <= 0.04045
                    ? component / 12.92
                    : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.r)
                + 0.7152 * linear(color.g)
                + 0.0722 * linear(color.b)
        }
        func contrast(
            _ foreground: CGColor, over background: CGColor
        ) -> Double? {
            guard let fg = rgba(foreground), let bg = rgba(background) else { return nil }
            let resolved = composite(fg, over: bg)
            let foregroundLuminance = luminance(resolved)
            let backgroundLuminance = luminance((r: bg.r, g: bg.g, b: bg.b))
            return (max(foregroundLuminance, backgroundLuminance) + 0.05)
                / (min(foregroundLuminance, backgroundLuminance) + 0.05)
        }
        guard let contrastRow = rows.first(where: { $0.variant == .card }) else {
            throw fail("sidebar-ux-check.accessibility.contrast: no card row witness")
        }
        let roleSet: [(name: String, configure: (AgentInboxView, UUID) -> Bool)] = [
            ("selected", { inbox, id in inbox.selectRowForQA(id: id) }),
            ("hover", { inbox, id in inbox.hoverRowForQA(id: id) }),
            ("route-active", { inbox, id in inbox.openAgentId = id; return true }),
        ]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let theme: TokenTheme = appearanceName == .darkAqua ? .dark : .light
            for width in widths {
                var normalRatios: [String: Double] = [:]
                var highRatios: [String: Double] = [:]
                var highFills: [String: CGColor] = [:]
                for increased in [false, true] {
                    for role in roleSet {
                        let label = "sidebar-ux-check.accessibility.contrast@\(Int(width))pt.\(appearanceName.rawValue).\(role.name).high=\(increased)"
                        let probe = try makeSidebarProbeHost(
                            width: width, height: probeHeight, appearanceName: appearanceName)
                        probe.inbox.prefersIncreasedContrast = { increased }
                        probe.inbox.reload(rows: [contrastRow])
                        probe.inbox.layoutForQA()
                        guard role.configure(probe.inbox, contrastRow.id) else {
                            throw fail("\(label): could not drive the live \(role.name) interaction state")
                        }
                        probe.inbox.layoutForQA()
                        guard let geometry = probe.inbox.qaRowGeometriesForQA.first,
                              geometry.surfaceRole?.rawValue == "sidebar\(role.name == "route-active" ? "Active" : role.name.capitalized)",
                              let fill = geometry.resolvedFill,
                              let surrounding = probe.inbox.layer?.backgroundColor,
                              let ratio = contrast(fill, over: surrounding) else {
                            throw fail("\(label): live painted fill or surrounding panel was not measurable")
                        }
                        if increased {
                            highRatios[role.name] = ratio
                            highFills[role.name] = fill
                        } else {
                            normalRatios[role.name] = ratio
                        }
                    }
                }
                guard roleSet.allSatisfy({
                    guard let normal = normalRatios[$0.name], let high = highRatios[$0.name] else { return false }
                    return high > normal + 0.001
                }) else {
                    throw fail("sidebar-ux-check.accessibility.contrast@\(Int(width))pt.\(appearanceName.rawValue): Increase Contrast did not produce a measured ratio increase for every interaction role (normal=\(normalRatios), high=\(highRatios))")
                }
                guard let selected = highRatios["selected"],
                      let hover = highRatios["hover"],
                      let active = highRatios["route-active"],
                      selected < hover, hover < active,
                      let normalSelected = normalRatios["selected"],
                      let normalHover = normalRatios["hover"],
                      let normalActive = normalRatios["route-active"],
                      normalSelected < normalHover, normalHover < normalActive else {
                    throw fail("sidebar-ux-check.accessibility.contrast@\(Int(width))pt.\(appearanceName.rawValue): selected < hover < route-active paint ordering was not preserved (normal=\(normalRatios), high=\(highRatios))")
                }
                // Stronger background contrast cannot spend the foreground's
                // accessibility budget. Measure the actual high-contrast paint
                // against the same complete text/status/control roster and floors
                // as SidebarTokens, rather than checking only fill versus panel.
                for role in roleSet {
                    guard let fill = highFills[role.name] else {
                        throw fail("sidebar-ux-check.accessibility.contrast@\(Int(width))pt.\(appearanceName.rawValue): no high-contrast fill for \(role.name)")
                    }
                    for pair in SidebarTokens.documentedPairs {
                        let foreground = pair.color.cgColor(for: theme)
                        guard let ratio = contrast(foreground, over: fill),
                              ratio + 0.0001 >= pair.floor else {
                            throw fail("sidebar-ux-check.accessibility.contrast@\(Int(width))pt.\(appearanceName.rawValue): \(pair.foreground) on high-contrast \(role.name) measured \(contrast(foreground, over: fill) ?? -1):1 below \(pair.floor):1")
                        }
                    }
                }
                assertions += 11
            }
        }

        // Divider semantics are owned by the production split-view controller;
        // this check consumes its live AX splitter rather than a copied label.
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp?.appearance = NSAppearance(named: appearanceName)
            for width in widths {
                let splitWidth = width + WorkspaceSidebarConfig.contentMinimumWidth + 2
                let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: splitWidth, height: 420))
                split.isVertical = true
                split.dividerStyle = .thin
                let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: 420))
                split.addArrangedSubview(sidebar)
                split.addArrangedSubview(NSView(frame: NSRect(
                    x: width + 2, y: 0, width: WorkspaceSidebarConfig.contentMinimumWidth, height: 420)))
                split.setPosition(width, ofDividerAt: 0)
                split.layoutSubtreeIfNeeded()
                let label = "sidebar-ux-check.accessibility.divider@\(Int(width))pt.\(appearanceName.rawValue)"
                guard split.accessibilityRole() == .splitGroup,
                      sidebar.resizeAccessibilityRoleForQA == .splitter,
                      sidebar.resizeAccessibilityLabelForQA?.hasPrefix("Resize sidebar, ") == true else {
                    throw fail("\(label): live resize divider lost split-group/splitter role or direction label")
                }
                assertions += 3
            }
        }
        return assertions
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
    /// P2.6 removes the two old slim entries from this set: the slim line now
    /// drops its branch and/or time lane before the name, so a name that fits the
    /// glyph-plus-name lane is no longer a fixed-lane truncation. Any slim name
    /// that truly outruns that final line would still belong here, but the corpus
    /// has no such witness. Card-only entries remain the last rung of the name
    /// ladder, and `expectRowBandsAndSacrificeOrder` continues to scope itself to
    /// card rows because slim rows use their own measured tier vocabulary.
    private static let namesLongerThanTheRow: Set<String> = [
        "row14.title@min", "row16.title@min", "row17.title@min", "row18.title@min", "row19.title@min",
        "row20.title@min", "row21.title@min", "row22.title@min", "row23.title@min", "row24.title@min",
        "row25.title@min", "row26.title@min", "row27.title@min", "row28.title@min", "row29.title@min",
        "row30.title@min", "row31.title@min", "row32.title@min", "row33.title@min", "row34.title@min",
        "row35.title@min", "row36.title@min", "row37.title@min", "row38.title@min", "row39.title@min",
        "row4.title@min", "row40.title@min", "row41.title@min", "row42.title@min", "row43.title@min",
        "row44.title@min", "row47.title@min",
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
    ///  · No `meta@*` entry survives this pass: removing the repeated model id
    ///    leaves enough width for the role/rollup slot after the branch reaches its
    ///    yielding floor. That is a P2.4 healing, not permission to make the role
    ///    line required again.
    ///
    /// NO `project@*` ENTRY SURVIVES, and its absence is P2.2's result rather than
    /// an omission: the caption is the FIRST rung, so the tightest tier stops
    /// drawing it, and a hidden label is not measured. All 4 are gone — `row2`'s
    /// at min the moment the project stopped sharing the name's line (P2.1), and
    /// `row48`'s three when `RowFitTier.captionHidden` took the over-long project
    /// off the row entirely (P2.2). The fact itself is not lost: it is folded into
    /// the cell's accessibility label, which `checkSidebarFitTierLadder` asserts.
    private static let sacrificedByOrder: Set<String> = [
        "row0.branch@min",
        "row14.branch@min", "row15.branch@min", "row16.branch@min", "row17.branch@min", "row18.branch@min",
        "row19.branch@min", "row20.branch@min", "row21.branch@min", "row22.branch@min", "row23.branch@min",
        "row24.branch@min", "row25.branch@min", "row26.branch@min", "row27.branch@min", "row28.branch@min",
        "row29.branch@min", "row30.branch@min", "row31.branch@min", "row32.branch@min",
        "row33.branch@min", "row34.branch@min", "row35.branch@min", "row36.branch@min", "row37.branch@min",
        "row38.branch@min", "row39.branch@min", "row40.branch@min", "row41.branch@min", "row42.branch@min",
        "row43.branch@min", "row44.branch@min", "row46.branch@min", "row47.branch@min",
    ]

    /// P2.5/P2.6 DELTA: the gate pins `LabFixtures.inboxNow`, so row50's time is
    /// `in 3h 45m` and row51's is `12m ago`, never the machine-date value an
    /// unpinned probe would measure. P2.6 then drops the slim branch before the
    /// name when that measured line does not fit; the two slim names and branches
    /// therefore leave this table rather than being excused as truncations.
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
        let expectedDefault = try independentlyExpectedDefaultFanout(rows)
        let expectedDefaultIDs = expectedDefault.visibleIDs
        guard let fanoutParentID = expectedDefault.remainders.first?.parentID else {
            throw fail("ui-geometry-check: sidebar gate corpus has no fan-out parent")
        }
        var corpusIndexByID: [UUID: Int] = [:]
        for (index, row) in rows.enumerated() { corpusIndexByID[row.id] = index }

        let probeHeight = sidebarProbeHeight(for: rows)

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
                // Match the materialization contract used by the live sidebar
                // leg: pin the relative-time clock and open the shelf BEFORE
                // applying rows. Applying into a closed/offscreen shelf builds
                // no parked cells and makes this gate pass vacuously.
                probe.inbox.clock = { LabFixtures.inboxNow }
                probe.inbox.toggleShelf()
                probe.inbox.reload(rows: rows)
                probe.inbox.layoutForQA()
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.layoutForQA()
                try assertDefaultFanoutAccounting(
                    probe,
                    rows: rows,
                    expected: expectedDefault,
                    label: "ui-geometry-check@\(gate.name).\(appearanceName.rawValue)")
                try checkNestedFanoutProbe(width: gate.width, appearanceName: appearanceName)
                guard probe.inbox.rowIdsForQA == expectedDefaultIDs,
                      probe.inbox.fanoutRemainderParentIDsForQA == Set([fanoutParentID]),
                      probe.inbox.fanoutRemainderTitlesForQA.count == 1 else {
                    throw fail("ui-geometry-check: sidebar gate lost the bounded default contract at \(gate.name)")
                }
                guard probe.inbox.clickFanoutRemainderForQA(parentId: fanoutParentID) else {
                    throw fail("ui-geometry-check: sidebar gate could not press the live fan-out remainder at \(gate.name)")
                }
                probe.inbox.layoutForQA()
                probe.host.layoutSubtreeIfNeeded()
                probe.inbox.layoutForQA()
                let geometries = probe.inbox.qaRowGeometriesForQA
                guard geometries.count == rows.count,
                      probe.inbox.rowIdsForQA == InboxSort.sortForInbox(rows: rows).map(\.id),
                      probe.inbox.fanoutRemainderParentIDsForQA.isEmpty else {
                    throw fail("ui-geometry-check: sidebar gate materialized \(geometries.count) rows of \(rows.count) at \(gate.name) after expansion")
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
            // `apply` is a live view entry point and stamps its first display from
            // the wall clock. Drive the same timer seam to the presenter's pinned
            // 65-second value before measuring, so this offscreen assertion is not
            // a machine-date probe.
            header.qaTick(now: Date(timeIntervalSince1970: 165))
            header.layoutSubtreeIfNeeded()
            guard let renderedElapsed = header.qaElapsed,
                  let elapsedFrame = header.qaElapsedFrame else {
                throw fail("agent header: working presentation did not materialize its elapsed lane at \(Int(width))pt")
            }
            let renderedNeed = measuredElapsedNeed(renderedElapsed)
            guard renderedElapsed == AgentElapsedFormatter.prefixedLabel(65),
                  Double(elapsedFrame.width) + 0.5 >= renderedNeed else {
                throw fail(String(format: "sidebar-ux-check.elapsed.header@%.0fpt: tile rendered '%@' for 65.0s, need %.1fpt drawable width but got %.1fpt",
                                   width, renderedElapsed, renderedNeed, elapsedFrame.width))
            }
            // THE WIDEST RENDERED FORM, not just a short one. Every case this leg drove
            // was 7 glyphs (`· 1m 5s`, `· >999d`), which a lane sized from the BARE
            // forms also fits — so attempt 1's exact regression (a 43pt lane against a
            // 49-55pt need, clipped with no ellipsis) passed this assertion. Tick to a
            // 9-glyph form so the lane must be sized from what it RENDERS.
            for (interval, expected) in [(86_399.0, "23h 59m"), (3_599.0, "59m 59s")] {
                header.qaTick(now: Date(timeIntervalSince1970: interval + 100))
                header.layoutSubtreeIfNeeded()
                guard let wide = header.qaElapsed, let wideFrame = header.qaElapsedFrame else {
                    throw fail("agent header: no elapsed lane for the widest rendered form at \(Int(width))pt")
                }
                let wideNeed = measuredElapsedNeed(wide)
                guard wide == AgentElapsedFormatter.prefixedLabel(interval) else {
                    throw fail("agent header: expected the formatter to emit '\(expected)' for \(interval)s, rendered '\(wide)'")
                }
                guard Double(wideFrame.width) + 0.5 >= wideNeed else {
                    throw fail(String(format: "ui-geometry-check.elapsed.header@%.0fpt: the lane is %.1fpt but rendering '%@' needs %.1fpt — size the lane from the RENDERED string, prefix included (P2.5)",
                                       width, wideFrame.width, wide, wideNeed))
                }
            }
            header.qaTick(now: Date(timeIntervalSince1970: 165))
            header.layoutSubtreeIfNeeded()
            let elapsedBefore = header.qaElapsedFrame
            header.qaTick(now: Date(timeIntervalSince1970: 226))
            header.layoutSubtreeIfNeeded()
            guard header.qaElapsedFrame == elapsedBefore else {
                throw fail("agent header: a timer tick moved the elapsed label frame — ticks must not relayout")
            }
            guard let tickElapsed = header.qaElapsed,
                  let tickFrame = header.qaElapsedFrame,
                  Double(tickFrame.width) + 0.5 >= measuredElapsedNeed(tickElapsed) else {
                throw fail("agent header: a timer tick rendered an elapsed form wider than its fixed drawable lane")
            }
            let widestHeaderSeconds = 1_000 * TimeInterval(86_400)
            header.qaTick(now: Date(timeIntervalSince1970: 100 + widestHeaderSeconds))
            header.layoutSubtreeIfNeeded()
            guard let widestElapsed = header.qaElapsed,
                  let widestFrame = header.qaElapsedFrame,
                  widestElapsed == AgentElapsedFormatter.prefixedLabel(widestHeaderSeconds),
                  Double(widestFrame.width) + 0.5 >= measuredElapsedNeed(widestElapsed) else {
                throw fail("agent header: bounded widest elapsed form exceeded its rendered fixed lane")
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
        let effortGeometryTileWidths = Set([CGFloat(320), 480, 560])
        for width in [CGFloat(320), 480, 560, 640, 900] {
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
                guard tile.qaLocationText
                        == "Home Continuum · Where Sources/ContinuumRevived",
                      tile.qaWhatText == "What Reading design-system/Tokens.swift",
                      !tile.qaWhereOutboundMarkerVisible,
                      tile.qaWhatOutboundMarkerVisible,
                      tile.qaLocationMarkerLanesDoNotOverlapText,
                      tile.qaLocationContentFitsBounds else {
                    throw fail("\(label): integrated Home/Where/What lost its content or fixed external-marker lane")
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
                // P5.5 defect 4 / Wave 1 footer sizing: text truncation is invisible
                // to the frame-only checks above — a label ellipsizing inside its own
                // well-contained frame passes every one of them. Whenever the footer's
                // measured fit says its current titles fit, both pickers must hold
                // their measured width and render the selected title verbatim. At the
                // real 320/480/560 tile widths, the effort control is additionally
                // driven through every required reasoning value and must outrank the
                // flexible model control, so its selected title never ellipsizes while
                // the model is the pressure-release valve.
                let footer = tile.qaProviderFooterView
                try checkFooterCurrentTitles(footer, label: label)
                if effortGeometryTileWidths.contains(width) {
                    try checkProviderFooterEffortSizing(tile, width: width, label: label)
                }
            }
        }
    }

    private static func checkFooterCurrentTitles(_ footer: AgentComposerFooterView, label: String) throws {
        footer.layoutSubtreeIfNeeded()
        guard !footer.qaHasVisibleContextLabel else {
            throw fail("\(label): footer kept the visible inert Next turn label instead of leaving next-turn context to the picker accessibility labels")
        }
        guard footer.qaFitsCurrentTitles else {
            throw fail("\(label): the footer's own measured fit rejects its current titles — the fit tiers (full → abbreviated) must converge at every gate width")
        }
        for (name, button) in [("model", footer.modelButton), ("effort", footer.effortButton)] {
            guard button.frame.width >= button.intrinsicContentSize.width - 0.5 else {
                throw fail("\(label): \(name) picker squeezed below its measured width (frame \(button.frame.width), needs \(button.intrinsicContentSize.width)) — its title will ellipsize")
            }
            try checkChoiceTitleDrawsWithoutTruncation(button, name: name, label: label)
        }
    }

    private static func checkProviderFooterEffortSizing(_ tile: ManagedAgentTileNSView, width: CGFloat, label: String) throws {
        let effortValues = ["minimal", "medium", "high", "xhigh"].filter {
            AgentModelConfig.thinkingOptions.contains($0)
        }
        guard effortValues.count == 4 else {
            throw fail("\(label): catalogue no longer contains the required effort geometry values; got \(AgentModelConfig.thinkingOptions)")
        }
        let stressModel = AgentModelConfig.modelOptions.last ?? AgentModelConfig.defaultModel
        for effort in effortValues {
            tile.applyProviderSettings(.init(model: stressModel, thinking: effort))
            tile.layoutSubtreeIfNeeded()
            let footer = tile.qaProviderFooterView
            footer.layoutSubtreeIfNeeded()
            let effortLabel = "\(label).effort=\(effort)"
            guard footer.effortButton.contentCompressionResistancePriority(for: .horizontal).rawValue
                    > footer.modelButton.contentCompressionResistancePriority(for: .horizontal).rawValue,
                  footer.effortButton.contentHuggingPriority(for: .horizontal).rawValue
                    > footer.modelButton.contentHuggingPriority(for: .horizontal).rawValue else {
                throw fail("\(effortLabel): effort no longer has stronger compression resistance/hugging than the flexible model control")
            }
            try checkChoiceTitleDrawsWithoutTruncation(footer.effortButton, name: "effort", label: effortLabel)
            guard footer.bounds.contains(footer.effortButton.frame),
                  footer.effortButton.frame.width + 0.5 >= footer.effortButton.intrinsicContentSize.width else {
                throw fail("\(effortLabel): effort control did not hold intrinsic width at real \(Int(width))pt tile width (frame \(footer.effortButton.frame.width), needs \(footer.effortButton.intrinsicContentSize.width))")
            }
            if footer.qaFitsCurrentTitles {
                try checkFooterCurrentTitles(footer, label: effortLabel)
            }
        }
    }

    private static func checkChoiceTitleDrawsWithoutTruncation(_ button: ChoiceButton, name: String, label: String) throws {
        button.layoutSubtreeIfNeeded()
        guard button.qaTitleDrawsWithoutTruncation else {
            throw fail("\(label): \(name) picker's title frame \(button.qaTitleFrameWidth)pt is narrower than measured title '\(button.qaRenderedTitle)' need \(button.qaMeasuredTitleWidth)pt — the cell will draw an ellipsis")
        }
    }

    /// Deterministic behavior/geometry gate for the reusable custom choice
    /// surface. The disabled selection assertion is the required negative path:
    /// every input route converges on `choose(id:)`, whose guard it exercises.
    private static func checkChoicePopover() throws -> Int {
        let items = [
            ChoiceItem(id: "fast", title: "Fast", detail: "Lower latency"),
            ChoiceItem(id: "balanced", title: "Balanced", detail: "Recommended"),
            ChoiceItem(id: "legacy", title: "Legacy", detail: "Unavailable", enabled: false, destructive: true),
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
        guard list.qaDestructiveIDs == Set(["legacy"]) else {
            throw fail("choice popover: destructive choice lost its semantic marker")
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

    /// Deterministic IMAGE WAVE 2A gate for semantic transcript media. The
    /// renderer consumes only opaque attachment IDs through an injected host-local
    /// provider; display names and content types never become paths or fetches.
    private static func checkImageRenderers() throws -> Int {
        func id(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }
        func attachmentID(_ value: String) -> AgentImageAttachmentID { AgentImageAttachmentID(rawValue: value)! }
        func metadata(
            _ rawID: String,
            name: String? = nil,
            type: String? = nil,
            bytes: UInt64? = nil,
            width: UInt? = nil,
            height: UInt? = nil
        ) -> AgentImageAttachmentMetadata {
            AgentImageAttachmentMetadata(
                id: attachmentID(rawID), displayName: name, contentType: type,
                byteCount: bytes, pixelWidth: width, pixelHeight: height
            )
        }
        func pngFile(named name: String, color: NSColor = .systemTeal) throws -> URL {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("continuum-image-renderer-\(UUID().uuidString)-\(name).png")
            let image = NSImage(size: NSSize(width: 8, height: 4))
            image.lockFocus()
            color.setFill()
            NSRect(x: 0, y: 0, width: 8, height: 4).fill()
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                throw fail("could not create PNG fixture")
            }
            try png.write(to: url, options: .atomic)
            return url
        }
        func thumbnail(size: NSSize, id attachmentID: AgentImageAttachmentID, revision: UInt64) -> AgentImageThumbnail {
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.systemTeal.setFill()
            NSRect(origin: .zero, size: size).fill()
            image.unlockFocus()
            return AgentImageThumbnail(attachmentID: attachmentID, revision: revision, image: image, pixelSize: size)
        }

        guard try AgentBlockRendererRegistry.production.renderer(for: .image) is AgentImageRenderer,
              try AgentBlockRendererRegistry.production.renderer(for: .imageGallery) is AgentImageGalleryRenderer else {
            throw fail("production registry did not resolve image and image-gallery renderers")
        }

        let localID = attachmentID("opaque-local-image")
        let processingID = attachmentID("opaque-processing-image")
        let missingID = attachmentID("opaque-missing-image")
        let failedID = attachmentID("opaque-failed-image")
        var snapshots: [AgentImageAttachmentID: AgentImageResourceSnapshot] = [
            localID: AgentImageResourceSnapshot(
                attachmentID: localID,
                state: .available,
                revision: 1,
                pixelSize: NSSize(width: 800, height: 400),
                displayName: "/Users/dylan/private/resolved-local.png",
                contentType: "image/png",
                byteCount: 1200
            ),
            processingID: AgentImageResourceSnapshot(attachmentID: processingID, state: .processing, revision: 1),
            missingID: AgentImageResourceSnapshot(attachmentID: missingID, state: .missing, revision: 1),
            failedID: AgentImageResourceSnapshot(attachmentID: failedID, state: .failed, revision: 1)
        ]
        var resolvedIDs: [AgentImageAttachmentID] = []
        var thumbnailRequests: [(AgentImageAttachmentID, NSSize, UInt64)] = []
        var invalidationHandlers: [AgentImageAttachmentID: @MainActor (UInt64) -> Void] = [:]
        var cancelledRequests = 0
        var pendingLargeThumbnailCompletions: [AgentImageAttachmentID: @MainActor (AgentImageThumbnailResult) -> Void] = [:]
        let provider = AgentImageResourceProvider(
            snapshot: { attachmentID in
                resolvedIDs.append(attachmentID)
                return snapshots[attachmentID] ?? AgentImageResourceSnapshot(attachmentID: attachmentID, state: .missing)
            },
            requestThumbnail: { attachmentID, target, revision, completion in
                thumbnailRequests.append((attachmentID, target, revision))
                if attachmentID.rawValue.hasPrefix("large-") {
                    pendingLargeThumbnailCompletions[attachmentID] = completion
                    return AgentImageThumbnailRequest {
                        cancelledRequests += 1
                        pendingLargeThumbnailCompletions.removeValue(forKey: attachmentID)
                    }
                }
                completion(.success(thumbnail(size: target, id: attachmentID, revision: revision)))
                return AgentImageThumbnailRequest { cancelledRequests += 1 }
            },
            observe: { attachmentID, invalidated in
                invalidationHandlers[attachmentID] = invalidated
                return AgentImageResourceObservation { invalidationHandlers.removeValue(forKey: attachmentID) }
            }
        )
        var actions: [AgentRenderAction] = []
        var presentationInvalidations: [AgentNodeID] = []
        let context = AgentRenderContext(
            actions: AgentRenderActions(
                perform: { actions.append($0) },
                disclosureState: { _, defaultValue in defaultValue },
                setDisclosureState: { _, _ in },
                presentationRevision: { _ in snapshots.values.map(\.revision).reduce(0, ^) },
                invalidatePresentation: { presentationInvalidations.append($0) }
            ),
            tokens: .transcript,
            appearance: .dark,
            imageResources: provider
        )

        let singlePayload = AgentImagePayload(
            attachment: metadata("opaque-local-image", name: "/tmp/semantic-name-never-a-path.png", type: "image/png", bytes: 1200, width: 800, height: 400),
            caption: [.text("Aspect-preserved local preview")]
        )
        let singleBlock = AgentBlock(id: id("image-single"), revision: 1, kind: .image, payload: .image(singlePayload))
        let singleHost = AgentBlockHostView()
        let singleHeight = try singleHost.measuredHeight(for: singleBlock, width: 320, context: context)
        guard singleHeight > 210, singleHeight < 250 else {
            throw fail("single image did not measure from inset-correct 2:1 aspect at 320pt, got \(singleHeight)")
        }
        singleHost.frame = NSRect(x: 0, y: 0, width: 320, height: singleHeight)
        try singleHost.apply(block: singleBlock, context: context)
        singleHost.layoutSubtreeIfNeeded()
        guard let singleView = singleHost.rendererView as? AgentImageGalleryView,
              singleView.qaVisibleCellCount == 1,
              singleView.cells[0].titleLabel.stringValue == "resolved-local.png",
              !singleView.cells[0].titleLabel.stringValue.contains("/Users"),
              singleView.cells[0].metadataLabel.stringValue.contains("Available locally"),
              singleView.cells[0].captionLabel.stringValue == "Aspect-preserved local preview",
              singleView.accessibilityLabel() == "Image" else {
            throw fail("single semantic image did not render sanitized local provider state, caption, and accessibility")
        }
        singleView.layoutSubtreeIfNeeded()
        guard let firstRequest = thumbnailRequests.first,
              firstRequest.0 == localID,
              firstRequest.2 == 1,
              firstRequest.1.width <= AgentImageGalleryView.maximumThumbnailPixelEdge,
              firstRequest.1.height <= AgentImageGalleryView.maximumThumbnailPixelEdge,
              singleView.cells[0].imageView.image != nil,
              !singleView.cells[0].imageView.isHidden,
              singleView.cells[0].stateLabel.isHidden else {
            throw fail("single image did not request and visibly install a synchronous bounded thumbnail: \(thumbnailRequests)")
        }

        let galleryPayload = AgentImageGalleryPayload(images: [
            singlePayload,
            AgentImagePayload(attachment: metadata("opaque-processing-image", name: "pending.png", type: "image/png", width: 640, height: 480)),
            AgentImagePayload(attachment: metadata("opaque-missing-image", name: "missing.png", type: "image/png")),
            AgentImagePayload(attachment: metadata("opaque-failed-image", name: "/secret/failed.png", type: "image/png\n/private/" + String(repeating: "x", count: 120)))
        ])
        let galleryBlock = AgentBlock(id: id("image-gallery"), revision: 1, kind: .imageGallery, payload: .imageGallery(galleryPayload))
        let galleryHost = AgentBlockHostView()
        let galleryHeight = try galleryHost.measuredHeight(for: galleryBlock, width: 360, context: context)
        galleryHost.frame = NSRect(x: 0, y: 0, width: 360, height: galleryHeight)
        try galleryHost.apply(block: galleryBlock, context: context)
        galleryHost.layoutSubtreeIfNeeded()
        guard let galleryView = galleryHost.rendererView as? AgentImageGalleryView,
              galleryView.qaVisibleCellCount == 4,
              Set(galleryView.qaVisibleAttachmentIDs) == Set([localID, processingID, missingID, failedID]),
              galleryView.cells[0].frame.minX < galleryView.cells[1].frame.minX,
              galleryView.cells[2].frame.minY > galleryView.cells[0].frame.minY else {
            throw fail("gallery did not build deterministic visible cells keyed by attachment IDs")
        }
        let stateTexts = galleryView.cells.map(\.stateLabel.stringValue)
        guard stateTexts.contains("Processing image…"),
              stateTexts.contains("Image unavailable on this host"),
              stateTexts.contains("Image failed"),
              !stateTexts.contains(where: { $0.contains("decoder") || $0.contains("/") }) else {
            throw fail("gallery did not map processing/missing/failure to bounded non-sensitive states: \(stateTexts)")
        }
        guard galleryView.accessibilityLabel() == "Image gallery, 4 images",
              galleryView.accessibilityChildren()?.count == 4 else {
            throw fail("gallery accessibility did not keep visible image order")
        }

        let localMenu = galleryView.cells[0].actionMenuForQA()
        let missingMenu = galleryView.cells.first(where: { $0.titleLabel.stringValue == "missing.png" })?.actionMenuForQA()
        guard localMenu.items.map(\.title) == ["Preview", "Copy Image", "Save As…", "Reveal in Finder"],
              localMenu.items.allSatisfy({ $0.isEnabled }),
              missingMenu?.items.allSatisfy({ !$0.isEnabled }) == true else {
            throw fail("image action menu did not gate local-only preview/copy/save/reveal affordances")
        }
        localMenu.performActionForItem(at: 0)
        localMenu.performActionForItem(at: 1)
        localMenu.performActionForItem(at: 2)
        localMenu.performActionForItem(at: 3)
        guard actions.count == 4 else { throw fail("image menu actions did not preserve opaque identity: \(actions)") }
        switch actions[0] {
        case let .previewImage(blockID, attachmentID): guard blockID == galleryBlock.id, attachmentID == localID else { throw fail("preview image action lost identity") }
        default: throw fail("first image action was not preview: \(actions[0])")
        }
        switch actions[1] {
        case let .copyImage(blockID, attachmentID): guard blockID == galleryBlock.id, attachmentID == localID else { throw fail("copy image action lost identity") }
        default: throw fail("second image action was not copy: \(actions[1])")
        }
        switch actions[2] {
        case let .saveImageAs(blockID, attachmentID): guard blockID == galleryBlock.id, attachmentID == localID else { throw fail("save image action lost identity") }
        default: throw fail("third image action was not save-as: \(actions[2])")
        }
        switch actions[3] {
        case let .revealImage(blockID, attachmentID): guard blockID == galleryBlock.id, attachmentID == localID else { throw fail("reveal image action lost identity") }
        default: throw fail("fourth image action was not reveal: \(actions[3])")
        }
        guard galleryView.cells[0].acceptsFirstResponder,
              galleryView.cells[0].performPreviewForQA(),
              actions.count == 5,
              galleryView.accessibilityChildren()?.count == galleryPayload.images.count else {
            throw fail("image gallery did not expose focusable cell and full logical AX preview traversal")
        }

        presentationInvalidations.removeAll()
        try galleryHost.apply(block: galleryBlock, context: context)
        galleryHost.layoutSubtreeIfNeeded()
        snapshots[processingID] = AgentImageResourceSnapshot(
            attachmentID: processingID,
            state: .available,
            revision: 2,
            pixelSize: NSSize(width: 1200, height: 300),
            displayName: "processed.png",
            canReveal: false
        )
        invalidationHandlers[processingID]?(2)
        galleryHost.layoutSubtreeIfNeeded()
        guard presentationInvalidations == [galleryBlock.id],
              galleryView.cells.first(where: { $0.titleLabel.stringValue == "processed.png" })?.metadataLabel.stringValue.contains("1200×300") == true else {
            throw fail("resource apply-again revision transition did not invalidate measurement/presentation with current gated actions")
        }
        let metadataStrings = galleryView.cells.map(\.metadataLabel.stringValue)
        guard !metadataStrings.contains(where: { $0.contains("/private") || $0.contains("\n") || $0.contains(String(repeating: "x", count: 80)) }) else {
            throw fail("image metadata exposed unsanitized or unbounded content type: \(metadataStrings)")
        }

        let duplicatePayload = AgentImageGalleryPayload(images: [singlePayload, singlePayload, AgentImagePayload(attachment: metadata("opaque-missing-image", name: "missing.png", type: "image/png"))])
        let duplicateBlock = AgentBlock(id: id("image-gallery-duplicates"), revision: 1, kind: .imageGallery, payload: .imageGallery(duplicatePayload))
        let duplicateHost = AgentBlockHostView()
        let duplicateHeight = try duplicateHost.measuredHeight(for: duplicateBlock, width: 360, context: context)
        duplicateHost.frame = NSRect(x: 0, y: 0, width: 360, height: duplicateHeight)
        try duplicateHost.apply(block: duplicateBlock, context: context)
        duplicateHost.layoutSubtreeIfNeeded()
        guard let duplicateView = duplicateHost.rendererView as? AgentImageGalleryView,
              duplicateView.qaVisibleAttachmentIDs.filter({ $0 == localID }).count == 2,
              duplicateView.cells.filter({ $0.titleLabel.stringValue == "resolved-local.png" }).count == 2,
              Set(duplicateView.cells.map { ObjectIdentifier($0) }).count == duplicateView.cells.count else {
            throw fail("duplicate attachment IDs were not represented as distinct presentation occurrences")
        }

        let largeImages = (0..<100).map { index in
            AgentImagePayload(attachment: metadata("large-\(index)", name: "large-\(index).png", type: "image/png", width: 640, height: 480))
        }
        for index in 0..<100 {
            snapshots[attachmentID("large-\(index)")] = AgentImageResourceSnapshot(
                attachmentID: attachmentID("large-\(index)"), state: .available, revision: 1,
                pixelSize: NSSize(width: 640, height: 480), displayName: "large-\(index).png"
            )
        }
        let largeBlock = AgentBlock(id: id("image-gallery-large"), revision: 1, kind: .imageGallery, payload: .imageGallery(.init(images: largeImages)))
        let largeHost = AgentBlockHostView()
        largeHost.translatesAutoresizingMaskIntoConstraints = true
        let largeHeight = try largeHost.measuredHeight(for: largeBlock, width: 360, context: context)
        guard largeHeight > AgentImageGalleryView.maximumGalleryViewportHeight else {
            throw fail("large gallery did not hand full height to the outer transcript scroll owner: \(largeHeight)")
        }
        largeHost.frame = NSRect(x: 0, y: 0, width: 360, height: largeHeight)
        let outerTranscriptScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: AgentImageGalleryView.maximumGalleryViewportHeight))
        outerTranscriptScroll.drawsBackground = false
        outerTranscriptScroll.hasVerticalScroller = true
        outerTranscriptScroll.documentView = largeHost
        outerTranscriptScroll.contentView.postsBoundsChangedNotifications = true
        outerTranscriptScroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: max(0, largeHeight - AgentImageGalleryView.maximumGalleryViewportHeight)))
        try largeHost.apply(block: largeBlock, context: context)
        outerTranscriptScroll.layoutSubtreeIfNeeded()
        largeHost.layoutSubtreeIfNeeded()
        guard let largeView = largeHost.rendererView as? AgentImageGalleryView,
              largeView.qaVisibleCellCount < 20,
              largeView.qaVisibleCellCount < largeImages.count else {
            throw fail("large gallery materialized unbounded cells before outer scroll: \(String(describing: (largeHost.rendererView as? AgentImageGalleryView)?.qaVisibleCellCount))")
        }
        let initialLargeIDs = largeView.qaVisibleAttachmentIDs
        let initialLargeCells = Set(largeView.cells.map { ObjectIdentifier($0) })
        let cancelledBeforeScroll = cancelledRequests
        outerTranscriptScroll.contentView.setBoundsOrigin(.zero)
        outerTranscriptScroll.reflectScrolledClipView(outerTranscriptScroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: outerTranscriptScroll.contentView)
        largeView.needsLayout = true
        largeView.layoutSubtreeIfNeeded()
        largeHost.layoutSubtreeIfNeeded()
        let scrolledLargeIDs = largeView.qaVisibleAttachmentIDs
        let scrolledLargeCells = Set(largeView.cells.map { ObjectIdentifier($0) })
        guard !initialLargeIDs.isEmpty,
              !scrolledLargeIDs.isEmpty,
              initialLargeIDs != scrolledLargeIDs,
              largeView.qaVisibleCellCount < 20,
              !initialLargeCells.intersection(scrolledLargeCells).isEmpty,
              cancelledRequests > cancelledBeforeScroll,
              largeView.qaReusePoolCount < 20 else {
            throw fail("large gallery did not scroll lazily with reuse/pool/cancellation checks: before=\(initialLargeIDs.prefix(4)) after=\(scrolledLargeIDs.prefix(4)) visible=\(largeView.qaVisibleCellCount) pool=\(largeView.qaReusePoolCount) cancelled=\(cancelledRequests - cancelledBeforeScroll)")
        }

        let sourceA = try pngFile(named: "source-a")
        let sourceB = try pngFile(named: "source-b", color: .systemPink)
        var actionResources: [AgentImageAttachmentID: AgentImageActionResource] = [localID: AgentImageActionResource(attachmentID: localID, localFileURL: sourceA)!]
        var copiedFrom: URL?
        func own(_ action: AgentRenderAction) {
            guard case let .copyImage(_, attachmentID) = action,
                  let resource = actionResources[attachmentID] else { return }
            copiedFrom = resource.localFileURL
        }
        actionResources[localID] = AgentImageActionResource(attachmentID: localID, localFileURL: sourceB)!
        own(.copyImage(blockID: galleryBlock.id, attachmentID: localID))
        guard copiedFrom == sourceB else { throw fail("image action owner did not re-resolve attachment at click time") }

        let pasteboard = NSPasteboard(name: .init("continuum.image-copy-check.\(UUID().uuidString)"))
        guard AgentImageAppKitActions.copyFileImageContent(localFileURL: sourceB, to: pasteboard),
              pasteboard.canReadObject(forClasses: [NSImage.self], options: nil),
              pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.isEmpty != false else {
            throw fail("Copy Image did not place actual image content without exposing a file URL")
        }
        if let remote = URL(string: "https://example.com/image.png") {
            let previewer = AgentImageQuickPreviewController()
            guard previewer.canPreview(localFileURL: sourceB), !previewer.canPreview(localFileURL: remote) else {
                throw fail("Quick Preview seam accepted a non-file URL or rejected a valid image file")
            }
        }
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("continuum-image-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let destination = directoryURL.appendingPathComponent("dest.png")
        try "keep me".write(to: destination, atomically: true, encoding: .utf8)
        guard (try? AgentImageAppKitActions.saveFileImageContent(from: sourceB, to: directoryURL)) == false else {
            throw fail("save unexpectedly succeeded over a directory destination")
        }
        guard (try? String(contentsOf: destination)) == "keep me" else {
            throw fail("failed save removed or replaced the existing destination before success")
        }
        enum InducedReplaceFailure: Error { case fail }
        var failingOperations = AgentImageFileOperations.fileManager
        failingOperations.replaceItem = { _, _ in throw InducedReplaceFailure.fail }
        do {
            _ = try AgentImageAppKitActions.saveFileImageContent(from: sourceB, to: destination, fileOperations: failingOperations)
            throw fail("save unexpectedly succeeded when destination replacement was induced to fail")
        } catch InducedReplaceFailure.fail {}
        guard (try? String(contentsOf: destination)) == "keep me" else {
            throw fail("induced replacement failure did not preserve the original destination")
        }
        guard try AgentImageAppKitActions.saveFileImageContent(from: sourceB, to: destination),
              AgentImageFileValidator.validatedLocalImageFile(destination) != nil else {
            throw fail("save did not atomically replace destination with image content")
        }
        guard (try? AgentImageAppKitActions.saveFileImageContent(from: sourceB, to: sourceB)) == false,
              AgentImageFileValidator.validatedLocalImageFile(sourceB) != nil else {
            throw fail("same-source save was not rejected safely")
        }
        let textFile = directoryURL.appendingPathComponent("not-image.txt")
        try "not image".write(to: textFile, atomically: true, encoding: .utf8)
        guard AgentImageFileValidator.validatedLocalImageFile(textFile) == nil,
              AgentImageFileValidator.validatedLocalImageFile(directoryURL) == nil else {
            throw fail("file validation accepted a non-image or directory")
        }

        guard resolvedIDs.contains(localID), !resolvedIDs.contains(attachmentID("semantic-name-never-a-path.png")), cancelledRequests >= 0 else {
            throw fail("image renderer resolved anything other than opaque attachment IDs")
        }
        return 9
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
