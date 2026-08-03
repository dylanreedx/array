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

    private static func checkSidebarProbe(
        _ probe: SidebarProbeHost, rows: [AgentInboxRow], width: CGFloat,
        appearanceName: NSAppearance.Name
    ) throws -> (cells: Int, labels: Int, truncated: Int) {
        let label = "sidebar-ux-check@\(Int(width))pt.\(appearanceName.rawValue)"
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
        for row in rows {
            guard let geometry = geometryByID[row.id],
                  geometry.state == row.state,
                  geometry.variant == row.variant else {
                throw fail("\(label): live row \(row.id.uuidString) lost its state or resolved variant")
            }
            guard let borderWidth = geometry.paintedBorderWidth,
                  borderWidth.isFinite, borderWidth >= 0 else {
                throw fail("\(label): '\(row.title)' has no finite painted border width")
            }
            guard let fill = geometry.resolvedFill, fill.alpha > 0 else {
                throw fail("\(label): '\(row.title)' has no resolved painted fill")
            }
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
                ) + 4
                guard abs(measurement.neededWidth - measuredNeed) <= 0.01 else {
                    throw fail("\(label): '\(row.title)' label \(measurement.element) reported need \(measurement.neededWidth), measured \(measuredNeed) including the 4pt cell inset")
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
        }
        guard paintedStates == Set(InboxState.allCases) else {
            throw fail("\(label): paint seam covered \(paintedStates.count) states, expected every InboxState")
        }
        return (cells.count, labelCount, truncatedCount)
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

        let rows = LabFixtures.inboxRows()
        guard !rows.isEmpty else { throw fail("sidebar-ux-check: corpus is empty") }
        let widths: [CGFloat] = [
            CGFloat(WorkspaceSidebarConfig.minWidth),
            CGFloat(WorkspaceSidebarConfig.defaultWidth),
            320,
        ]
        var totalCells = 0
        var totalLabels = 0
        var totalTruncated = 0
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp?.appearance = NSAppearance(named: appearanceName)
            for width in widths {
                let probe = try makeSidebarProbeHost(
                    width: width, height: 620, appearanceName: appearanceName
                )
                let counts = try checkSidebarProbe(
                    probe, rows: rows, width: width, appearanceName: appearanceName
                )
                totalCells += counts.cells
                totalLabels += counts.labels
                totalTruncated += counts.truncated
            }
        }
        print(String(
            format: "UIProbeGeometry: sidebar UX seam materialized %d live row cells and measured %d labels across 220/280/320pt in Aqua and Dark Aqua; %d labels currently elide by drawable-width measurement; zero-size host rejected with a named error",
            totalCells, totalLabels, totalTruncated
        ))
    }

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
