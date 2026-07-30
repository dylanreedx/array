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
        let proseRows = try checkAssistantProseRenderer()
        let userPromptRows = try checkUserPromptRenderer()
        let codeRows = try checkCodeBlockRenderer()
        guard tightestDockSlack.isFinite else {
            throw fail("the approval dock was never measured — the fixture no longer opens an approval, so the derived height is ungated")
        }
        print(String(
            format: "UIProbeGeometry: %d managed-agent width/appearance pairs gated (widths %@); reusable block host identity/reset and 7-dimensional measurement key gated; assistant prose wraps %d semantic rows, user prompt wraps %d semantic rows, and fenced code preserves %d exact lines at 320pt with in-place streaming, dual-axis scrolling, capped height, copy, and inert controls; narrowest card fill ratio %.3f; approval dock derived height %.1fpt, tightest slack over its real content %.1fpt",
            probed, probeWidths.map { String(Int($0)) }.joined(separator: ","), proseRows, userPromptRows, codeRows,
            narrowestCardRatio, ApprovalDockView.preferredHeight, tightestDockSlack
        ))
    }

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
            throw fail("block measurement cache collapsed ID/kind/entry-role/revision/width/appearance/content-size keys (cache \(cacheCount), renderer \(rendererCount), expected 6)")
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
