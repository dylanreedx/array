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

        let entries = LabCatalog.entries(env: LabEnvironment(ghostty: nil, browserEngine: nil))
        guard let entry = entries.first(where: { $0.id == "tiles.managedAgent" }),
              case let .staticCard(_, make) = entry.content else {
            throw fail("missing tiles.managedAgent card")
        }

        var probed = 0
        var narrowestCardRatio = Double.infinity
        var tightestDockSlack = Double.infinity
        for width in probeWidths {
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let label = "managedAgent@\(Int(width))pt.\(appearanceName.rawValue)"
                let spec = UIProbe.Spec(
                    id: label, size: NSSize(width: width, height: 560), appearance: appearanceName
                )
                let probe = try UIProbe.render(spec, make: make)
                guard let tile = probe.view as? ManagedAgentTileNSView else {
                    throw fail("\(label): tiles.managedAgent did not vend ManagedAgentTileNSView")
                }
                guard let cardStack = firstDescendant(FlippedStackView.self, in: tile),
                      let scrollView = cardStack.enclosingScrollView else {
                    throw fail("\(label): no transcript stack inside a scroll view")
                }

                // Ingest at the probe's real size, so the scroll assertion is about
                // this geometry and not the fixture's 560x560 construction frame.
                for prompt in scrollWitnessPrompts { tile.appendUserPrompt(prompt) }
                tile.layoutSubtreeIfNeeded()

                try expectCount(
                    cardStack.arrangedSubviews.count,
                    tile.transcriptCardCount + tile.qaUserInputCardCount,
                    label: "\(label): transcript rows"
                )
                guard cardStack.arrangedSubviews.count >= 4 else {
                    throw fail("\(label): only \(cardStack.arrangedSubviews.count) transcript rows — the fixture is not exercising the stack")
                }

                try fills(child: scrollView, parent: tile, minRatio: 0.99, label: "\(label): transcript scroll view")
                for (index, card) in cardStack.arrangedSubviews.enumerated() {
                    try fills(
                        child: card, parent: tile, minRatio: 0.9,
                        label: "\(label): card \(index) (\(describe(card)))"
                    )
                    narrowestCardRatio = min(narrowestCardRatio, card.bounds.width / tile.bounds.width)
                }

                try expectNoZeroSizeViews(tile, label: label)
                // The transcript column, root-to-card: outer row stack, the scroll
                // view row that lost its width pin, its clip view, the document
                // stack, and every card in it.
                var ancestor = scrollView.superview
                while let view = ancestor, !(view is NSStackView) { ancestor = view.superview }
                guard let rowStack = ancestor as? NSStackView else {
                    throw fail("\(label): transcript scroll view is not inside a row stack")
                }
                var ambiguityScope: [(NSView, String)] = [(rowStack, "tile row stack"),
                                                          (scrollView, "transcript scroll view"),
                                                          (scrollView.contentView, "transcript clip view"),
                                                          (cardStack, "transcript stack")]
                for (index, card) in cardStack.arrangedSubviews.enumerated() {
                    ambiguityScope.append((card, "card \(index)"))
                }
                try expectNoAmbiguousLayout(ambiguityScope, label: label)
                try expectNoClipping(tile, label: label)
                try expectNoBrokenRequiredSizeConstraints(tile, label: label)
                try expectScrolledToBottom(scrollView, requireOverflow: true, label: "\(label): transcript")
                tightestDockSlack = min(tightestDockSlack, try dockSlack(in: tile, label: label))
                probed += 1
            }
        }

        guard probed == probeWidths.count * 2 else {
            throw fail("probed \(probed) width/appearance pairs, expected \(probeWidths.count * 2)")
        }
        try checkReusableAgentBlockHost()
        let composerCases = try checkGrowingComposerLayout()
        let transcriptLiveHosts = try checkTranscriptCollectionList()
        let streamingApplies = try checkIncrementalTranscriptBehavior()
        let proseRows = try checkAssistantProseRenderer()
        let userPromptRows = try checkUserPromptRenderer()
        let codeRows = try checkCodeBlockRenderer()
        let operationRows = try checkToolAndCommandRenderers()
        let exceptionalRows = try checkExceptionalRenderers()
        guard tightestDockSlack.isFinite else {
            throw fail("the approval dock was never measured — the fixture no longer opens an approval, so the derived height is ungated")
        }
        print(String(
            format: "UIProbeGeometry: %d managed-agent width/appearance pairs gated (widths %@); reusable block host identity/reset and 8-dimensional measurement key gated; composer grows through %d width/draft cases with an eight-visual-line cap and stable constraints; transcript collection virtualized 10000 rows into %d live hosts while preserving unaffected identity; 5000 streaming deltas coalesced into %d visual apply with anchored/selection-safe scrolling, copy, and ordered accessibility; assistant prose wraps %d semantic rows, user prompt wraps %d semantic rows, fenced code preserves %d exact lines, %d tool/command states preserve scoped disclosure, and %d exceptional states preserve request identity and opaque privacy at 320pt; narrowest card fill ratio %.3f; approval dock derived height %.1fpt, tightest slack over its real content %.1fpt",
            probed, probeWidths.map { String(Int($0)) }.joined(separator: ","), composerCases, transcriptLiveHosts, streamingApplies, proseRows, userPromptRows, codeRows, operationRows, exceptionalRows,
            narrowestCardRatio, ApprovalDockView.preferredHeight, tightestDockSlack
        ))
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

    // MARK: - The derived approval-dock height (P1.10)

    /// `ApprovalDockView.preferredHeight` minus the height its real content needs,
    /// at this probe's width. Must not go negative.
    ///
    /// This is the assertion that makes replacing the hardcoded 92pt honest. A
    /// derived height that under-reports its content does NOT show up as clipping:
    /// the dock's layout stack is pinned to all four edges, so AppKit compresses the
    /// labels inside it instead of spilling them, and `expectNoClipping` sees a
    /// stack that fits its parent exactly. Measured against `fittingSize`, the same
    /// question is answerable with a number.
    ///
    /// The dock must also be *visible* to be measurable — the fixture opens an
    /// approval (`managedAgentFixtureEvents(includeApproval: true)`), and a hidden
    /// dock is reported rather than skipped, so this cannot pass vacuously.
    ///
    /// Measured TWICE: as the fixture leaves it, and again with a detail line. The
    /// fixture's `requestOpened` carries `detail: nil`, so `detailLabel` is hidden
    /// and `NSStackView` drops both the row and its gap — the fixture alone
    /// therefore measures the dock's SHORT state and reports ~20pt of slack that is
    /// really the detail row the derivation correctly reserves (the dock must not
    /// change height when a detail arrives). The populated case is the one that can
    /// clip, so it is the one that has to be gated.
    private static func dockSlack(in tile: ManagedAgentTileNSView, label: String) throws -> Double {
        guard let dock = firstDescendant(ApprovalDockView.self, in: tile) else {
            throw fail("\(label): no ApprovalDockView in the tile")
        }

        func measure(_ phase: String) throws -> Double {
            guard !dock.isHidden else {
                throw fail("\(label) \(phase): the approval dock is hidden, so its derived height is unmeasured — the fixture must open an approval")
            }
            let needed = dock.qaContentFittingHeight
            guard needed > 0 else {
                throw fail("\(label) \(phase): the approval dock's content reports zero fitting height — nothing was measured")
            }
            let slack = Double(dock.bounds.height) - needed
            guard slack >= -0.5 else {
                throw fail(String(
                    format: "%@ %@: the approval dock is %.1fpt tall but its content needs %.1fpt — the derived height under-reports, and AppKit compresses the labels rather than spilling them, so no clipping assertion would catch it",
                    label, phase, dock.bounds.height, needed
                ))
            }
            return slack
        }

        let short = try measure("(no detail)")
        // A detail at the sanitiser's own 160-character ceiling, so the row is as
        // tall as the dock will ever have to make it.
        tile.setPendingApprovalForQA(
            kind: .commandExecutionApproval, requestId: "geometry-detail",
            detail: String(repeating: "swift build && swift test ", count: 12)
        )
        tile.layoutSubtreeIfNeeded()
        guard !dock.qaDetailText.isEmpty else {
            throw fail("\(label): the approval dock shows no detail text after one was set — the tall case is unmeasured")
        }
        return min(short, try measure("(with detail)"))
    }

    // MARK: - Regression witnesses
    //
    // Every edit below was applied, run, and observed to turn this check RED; the
    // quoted failures are the real output. All five are re-runnable by hand.
    //
    // 1 · Half-width transcript (the bug that shipped). In
    //     `ManagedAgentTileNSView.makeContentView()`, delete the four width pins:
    //         header.widthAnchor.constraint(equalTo: layout.widthAnchor),
    //         scrollView.widthAnchor.constraint(equalTo: layout.widthAnchor),
    //         approvalDock.widthAnchor.constraint(equalTo: layout.widthAnchor),
    //         composeRow.widthAnchor.constraint(equalTo: layout.widthAnchor)
    //     → "managedAgent@640pt…: transcript scroll view: spans 0.670 of parent
    //        width (429.0pt of 640.0pt), needs >= 0.990"
    //     Note it fails at 640pt and 900pt, not at 320pt: an unpinned column whose
    //     fitting width already exceeds the tile is clamped to full width anyway.
    //     That is exactly why the probe widths must include widths wider than the
    //     transcript's natural fitting width, and why `scrollWitnessPrompts` are
    //     short lines.
    //
    // 2 · Card/model parity. In `ManagedAgentTileNSView.reconcileCards()`, iterate
    //     an empty array:
    //         for card in [ManagedTranscriptCard]() {   // was: model.cards
    //     → "transcript rows: 0, expected 13"
    //
    // 3 · Newest card off-screen. Delete `scrollTranscriptToBottom()` from
    //     `appendUserPrompt(_:)`:
    //     → "transcript: clip offset 0.0, expected 689.0 (document 1037.0pt,
    //        clip 348.0pt)"
    //
    // 4 · Clipping. In `reconcileCards()`, make cards wider than their stack —
    //     `constant: 60` instead of `constant: -24`:
    //     → "…/TranscriptCardView#managedAgent.card.assistant-1 spills
    //        horizontally — frame x 0.0…380.0 outside parent 0…320.0"
    //
    // 5 · Invisible cards. In `reconcileCards()`, add
    //         view.heightAnchor.constraint(equalToConstant: 0).isActive = true
    //     → "…/TranscriptCardView#managedAgent.card.assistant-1 laid out to
    //        296.0x0.0"
    //
    // 6 · Unsatisfiable constraints. In `makeContentView()`, add a second required
    //     header height alongside the 52pt one:
    //         header.heightAnchor.constraint(equalToConstant: 90),
    //     → "…/NSStackView holds a broken required constraint — measured 52.0,
    //        needs == 90.0 (<NSLayoutConstraint … .height == 90 (active)>)"
    //
    // Not witnessed: `expectNoAmbiguousLayout`. Witness 1 — the one bug in this
    // tile that AppKit's ambiguity reporting is advertised to catch — is caught by
    // the fill-ratio gate first, and no edit found so far makes the scoped
    // transcript column report ambiguity without also breaking a stronger
    // assertion. It is kept as a cheap structural assertion, not a proven gate.
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
