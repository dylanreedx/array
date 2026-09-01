import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// WS5 — per-managed-agent-tile page zoom.
///
/// **What this leg is for.** The feature's failure modes are all invisible in a
/// screenshot of a working tile: a cache that aliases the 100% heights, a layout
/// fast path that early-returns on a zoom change, a scale that leaks between two
/// tiles through a shared static, a rung that survives into `canvas.json`, a
/// title bar that moves with the content. So every assertion below reads a
/// RENDERED OUTCOME from a real AppKit layout in a real (offscreen) window:
/// a solved constraint constant, a resolved font point size, a prepared row
/// frame, a hit test, a counter delta, an encoded byte string.
///
/// **Positive controls.** Half of this contract is "X must NOT change". Each of
/// those is paired with a counter proving the zoom path actually ran
/// (`qaPageZoomApplyCount`, `qaPageZoomScaledViewCount`,
/// `qaPageZoomTransitionCount`, `qaMeasurementMissCount`), because an assertion
/// that nothing moved is satisfied perfectly by a feature that does nothing.
@MainActor
enum ManagedAgentPageZoomChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func fail(_ message: String) -> Failure { Failure(message: message) }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw fail(message()) }
    }

    static func run() throws {
        try checkStepGeometryAtTwoTileSizes()
        try checkOuterChromeAndModelAreUntouched()
        try checkHitTargetsFollowTheirControls()
        try checkTheMeasurementKeyCarriesTheRung()
        try checkMeasurementInvalidatesOncePerRungAndIsSteadyOtherwise()
        try checkReaderStateSurvivesAZoom()
        try checkTailFollowSurvivesAZoomDuringStreaming()
        try checkMenuOffersTheRungAndDisablesTheEndStops()
        try checkShortcutRoutingOnRealEvents()
        try checkTwoTilesHoldDifferentRungs()
        try checkNothingIsPersistedAndRecreationResets()
        print(
            "ManagedAgentPageZoomChecks passed: six rungs reflow real AppKit geometry at 360x480 and "
            + "560x620 with no horizontal overflow at 150%, the tile's world frame / title bar / zone "
            + "stamp / canvas viewport are byte-identical across every rung, hit tests still land on "
            + "their controls, a rung change invalidates measurement exactly once and ten steady "
            + "repeats add none, the reader's anchor / selection / composer text / composer focus / "
            + "tool disclosure survive a rung change (tail-follow too, mid-stream), the menu shows the "
            + "percentage and disables both end stops, Command-equal / Command-Shift-equal / "
            + "Command-hyphen / Command-zero route while Command-C and Option-Command-equal fall "
            + "through, two tiles hold 150% and 80% at once with different resolved fonts, and nothing "
            + "reaches the Tile model, the canvas JSON or a zoom-named default — a rebuilt tile is 100%"
        )
    }

    // MARK: - Fixture

    private static func nodeID(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }

    /// A document with enough shape that a rung change has somewhere to show:
    /// prose that must re-wrap, a heading, a long unbroken token, fenced code,
    /// a tool call with a disclosure, and command output.
    private static func fixtureDocument(version: UInt64 = 1) -> (AgentDocument, [AgentNodeID]) {
        var entries: [AgentEntry] = []
        var ids: [AgentNodeID] = []
        func entry(_ suffix: String, role: AgentEntryRole, blocks: [AgentBlock]) {
            ids.append(contentsOf: blocks.map(\.id))
            entries.append(AgentEntry(
                id: nodeID("ws5-entry-\(suffix)"), revision: 1, role: role,
                provenance: .providerItem(provider: "ws5", itemID: "ws5-\(suffix)"),
                blocks: blocks
            ))
        }
        entry("prompt", role: .user, blocks: [
            AgentBlock(
                id: nodeID("ws5-prompt"), revision: 1, kind: .paragraph,
                payload: .paragraph([.text("Explain the page zoom contract in detail, please.")]))
        ])
        entry("answer", role: .assistant, blocks: [
            AgentBlock(
                id: nodeID("ws5-heading"), revision: 1, kind: .heading,
                payload: .heading(level: 2, content: [.text("Page zoom")])),
            AgentBlock(
                id: nodeID("ws5-prose"), revision: 1, kind: .paragraph,
                payload: .paragraph([.text(String(repeating:
                    "The transcript must reflow at the new metrics rather than being scaled as a "
                    + "picture, so every line wraps where the new font says it wraps. ", count: 4))])),
            AgentBlock(
                id: nodeID("ws5-longtoken"), revision: 1, kind: .paragraph,
                payload: .paragraph([.text(String(repeating: "unbreakable", count: 12))])),
            AgentBlock(
                id: nodeID("ws5-code"), revision: 1, kind: .fencedCode,
                payload: .fencedCode(AgentCodePayload(
                    language: "swift",
                    code: (1...12).map { "let line\($0) = \"a fairly long source line for wrapping\"" }
                        .joined(separator: "\n")))),
            AgentBlock(
                id: nodeID("ws5-tool"), revision: 1, kind: .toolCall,
                payload: .toolCall(AgentToolCallPayload(
                    name: "read", summary: "Read a file", status: .completed))),
            AgentBlock(
                id: nodeID("ws5-tail"), revision: 1, kind: .paragraph,
                payload: .paragraph([.text(String(repeating:
                    "Closing paragraph that gives the document enough height to scroll. ",
                    count: 8))]))
        ])
        return (AgentDocument(version: version, entries: entries), ids)
    }

    private static func makeTile(
        named title: String, size: NSSize
    ) throws -> (tile: ManagedAgentTileNSView, window: NSWindow, ids: [AgentNodeID]) {
        let model = Tile(
            id: UUID(),
            kind: .managedAgent,
            title: title,
            frame: TileFrame(x: 40, y: 60, width: Double(size.width), height: Double(size.height)),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        )
        let view = ManagedAgentTileNSView(tile: model)
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontOffscreenForChecks()
        guard let transcript = view.qaTranscriptForChecks else {
            throw fail("\(title): the tile has no transcript fixture")
        }
        // The tile may already have painted a version of its own, so the patch
        // starts from what the view actually applied rather than from an
        // assumption about it.
        let base = transcript.qaAppliedVersion
        let (document, ids) = fixtureDocument(version: base + 1)
        try transcript.apply(
            document: document,
            patch: try AgentDocumentPatch(
                fromVersion: base, toVersion: base + 1, inserted: ids))
        settle(view)
        return (view, window, ids)
    }

    private static func settle(_ view: NSView) {
        view.window?.layoutIfNeeded()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        if let tile = view as? ManagedAgentTileNSView,
           let transcript = tile.qaTranscriptForChecks {
            transcript.layoutSubtreeIfNeeded()
            transcript.collectionView.layoutSubtreeIfNeeded()
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    /// Every resolved font point size actually installed on a text-bearing view
    /// inside the content root — the screen's own answer, not a policy's.
    private static func resolvedFontSizes(in root: NSView) -> [CGFloat] {
        descendants(of: root).compactMap { view in
            if let field = view as? NSTextField { return field.font?.pointSize }
            if let text = view as? NSTextView { return text.font?.pointSize }
            if let button = view as? NSButton { return button.font?.pointSize }
            return nil
        }.sorted()
    }

    /// The font sizes of the tile's NON-VIRTUALIZED chrome — the header and the
    /// whole compose column, including the status row, the composer, the rails,
    /// the provider footer and the primary action.
    ///
    /// The transcript is deliberately excluded HERE: it virtualizes, so a bigger
    /// rung fits fewer rows in the viewport and the multiset of live text views
    /// legitimately shrinks. Comparing that set across rungs would measure the
    /// virtualizer, not the zoom. The transcript's own scaling is asserted
    /// through its measured row heights and its measurement identity instead.
    private static func stableFontSizes(_ tile: ManagedAgentTileNSView) -> [CGFloat] {
        (resolvedFontSizes(in: tile.qaPageZoomHeaderView)
            + resolvedFontSizes(in: tile.qaPageZoomComposeBackdrop)).sorted()
    }

    private static let steps = AgentPageZoom.steps.map(AgentPageZoom.init(percent:))

    // MARK: - 1. Six-step geometry, two tile sizes, no clipping at 150%

    private static func checkStepGeometryAtTwoTileSizes() throws {
        for size in [NSSize(width: 360, height: 480), NSSize(width: 560, height: 620)] {
            let label = "\(Int(size.width))x\(Int(size.height))"
            let fixture = try makeTile(named: "ws5-geometry-\(label)", size: size)
            defer { fixture.window.orderOut(nil) }
            let tile = fixture.tile
            guard let transcript = tile.qaTranscriptForChecks else {
                throw fail("\(label): no transcript")
            }

            var headerHeights: [CGFloat] = []
            var composeInsets: [CGFloat] = []
            var totalRowHeights: [CGFloat] = []
            var fontSums: [CGFloat] = []
            var interTurn: [CGFloat] = []

            for zoom in steps {
                tile.setPageZoom(zoom)
                settle(tile)
                try expect(tile.pageZoom == zoom, "\(label): the tile refused rung \(zoom.percent)")

                // The tile's own composition, read from the SOLVED constraint.
                headerHeights.append(tile.qaPageZoomHeaderHeightConstant)
                composeInsets.append(tile.qaPageZoomComposeColumnInsets.left)
                interTurn.append(transcript.qaScaledInterTurnSpacing)

                let rows = transcript.qaMeasuredRowHeights()
                try expect(!rows.isEmpty, "\(label) @\(zoom.percent)%: no prepared rows to measure")
                totalRowHeights.append(rows.reduce(0, +))

                let sizes = stableFontSizes(tile)
                try expect(sizes.count >= 4,
                           "\(label) @\(zoom.percent)%: only \(sizes.count) chrome text views found")
                fontSums.append(sizes.reduce(0, +))

                // The transcript's measurement identity has to carry the rung, or
                // every height above is a 100% height wearing a different label.
                // The bucket the list view HANDS the cache. Asserted by value,
                // deliberately: through the tile the scaled content insets also
                // move the width bucket, so heights differ at every rung whether
                // or not the scale bucket is passed — a height comparison cannot
                // see the shipped `.standard` default here. The OUTCOME witness
                // for the key itself is `checkTheMeasurementKeyCarriesTheRung`,
                // which holds the width still so the cover is removed.
                try expect(
                    transcript.qaMeasurementScaleBucket == zoom.percent,
                    "\(label) @\(zoom.percent)%: the transcript measures with scale bucket "
                    + "\(transcript.qaMeasurementScaleBucket)"
                )
                try expect(
                    transcript.qaPageZoomPercent == zoom.percent
                        && transcript.qaLayoutPageZoomPercent == zoom.percent,
                    "\(label) @\(zoom.percent)%: the transcript is still at "
                    + "\(transcript.qaPageZoomPercent)% / layout \(transcript.qaLayoutPageZoomPercent)%"
                )

                // No horizontal overflow, at ANY rung. A view wider than the box
                // that clips it is content the reader cannot reach.
                //
                // The comparison is against each view's NEAREST CLIPPING
                // ancestor, not always the content root, and a subtree inside a
                // scroll view that DELIBERATELY scrolls horizontally (a fenced
                // code block) is exempt — that is its shipped behaviour at 100%
                // and page zoom is not the ticket that changes it. Everything
                // else — the header, the composer, every rail, every transcript
                // row — has to fit.
                var examined = 0
                for view in descendants(of: tile.qaPageZoomContentRoot) where view.superview != nil {
                    var clipper: NSView = tile.qaPageZoomContentRoot
                    var scrollsHorizontally = false
                    var walker: NSView? = view.superview
                    while let current = walker, current !== tile.qaPageZoomContentRoot {
                        if let scroller = current.enclosingScrollView, scroller.hasHorizontalScroller {
                            scrollsHorizontally = true
                            break
                        }
                        if current is NSClipView { clipper = current; break }
                        walker = current.superview
                    }
                    guard !scrollsHorizontally else { continue }
                    let frame = view.convert(view.bounds, to: clipper)
                    guard frame.width > 0 else { continue }
                    examined += 1
                    try expect(
                        frame.maxX <= clipper.bounds.width + 1.0 && frame.minX >= clipper.bounds.minX - 1.0,
                        "\(label) @\(zoom.percent)%: \(type(of: view)) overflows its clipping box "
                        + "horizontally (\(frame.minX)…\(frame.maxX) vs "
                        + "\(clipper.bounds.minX)…\(clipper.bounds.width))"
                    )
                }
                try expect(
                    examined > 8,
                    "\(label) @\(zoom.percent)%: only \(examined) views were width-checked; the "
                    + "overflow sweep found almost nothing and proves almost nothing"
                )
                try expect(
                    transcript.qaScrollViewForChecks.horizontalScroller?.isHidden ?? true,
                    "\(label) @\(zoom.percent)%: the transcript grew a horizontal scroller"
                )
            }

            // Strictly monotonic in the rung — the whole point of the ladder.
            for (index, metrics) in [
                ("header height", headerHeights),
                ("compose column inset", composeInsets),
                ("inter-turn spacing", interTurn),
                ("summed row heights", totalRowHeights),
                ("summed font sizes", fontSums)
            ].enumerated() {
                _ = index
                let (name, values) = metrics
                for step in 1..<values.count {
                    try expect(
                        values[step] > values[step - 1],
                        "\(label): \(name) did not grow from \(steps[step - 1].percent)% to "
                        + "\(steps[step].percent)% (\(values[step - 1]) -> \(values[step]))"
                    )
                }
            }

            // 100% is an exact identity against a tile that never zoomed.
            let pristine = try makeTile(named: "ws5-pristine-\(label)", size: size)
            defer { pristine.window.orderOut(nil) }
            tile.setPageZoom(.default)
            settle(tile)
            try expect(
                stableFontSizes(tile) == stableFontSizes(pristine.tile),
                "\(label): returning to 100% did not restore the untouched tile's font sizes "
                + "(\(stableFontSizes(tile)) vs \(stableFontSizes(pristine.tile)))"
            )
            try expect(
                tile.qaPageZoomHeaderHeightConstant == pristine.tile.qaPageZoomHeaderHeightConstant,
                "\(label): returning to 100% did not restore the header height"
            )
        }
    }

    // MARK: - 2. Nothing outside the content boundary moves

    private static func checkOuterChromeAndModelAreUntouched() throws {
        let fixture = try makeTile(named: "ws5-outer", size: NSSize(width: 520, height: 560))
        defer { fixture.window.orderOut(nil) }
        let tile = fixture.tile

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let modelBefore = try encoder.encode(tile.tile)
        let outerFrameBefore = tile.frame
        let contentRootFrameBefore = tile.qaPageZoomContentRoot.frame

        var applies = 0
        for zoom in steps where zoom != tile.pageZoom {
            tile.setPageZoom(zoom)
            settle(tile)
            applies += 1
            try expect(
                tile.frame == outerFrameBefore,
                "@\(zoom.percent)%: the tile's own view frame moved \(outerFrameBefore) -> \(tile.frame)"
            )
            try expect(
                try encoder.encode(tile.tile) == modelBefore,
                "@\(zoom.percent)%: the Tile MODEL changed — page zoom reached persistence"
            )
            try expect(
                tile.qaPageZoomContentRoot.frame == contentRootFrameBefore,
                "@\(zoom.percent)%: the content ROOT's own frame moved; the scale boundary must "
                + "reflow its children, not resize itself"
            )
        }

        // Positive control: the assertions above are only meaningful if the zoom
        // path actually ran and actually reached views.
        try expect(applies > 0, "outer chrome: no rung was applied, every assertion above was vacuous")
        try expect(
            tile.qaPageZoomApplyCount == applies,
            "outer chrome: \(applies) rung changes produced \(tile.qaPageZoomApplyCount) applies"
        )
        try expect(
            tile.qaPageZoomScaledViewCount > 0,
            "outer chrome: the scalable walk reached 0 views — nothing inside the tile is scaling, "
            + "so 'the outside did not move' proves nothing"
        )
        // The zoom entry is ADDITIVE: it must be offered on the tile's own menu
        // seam without displacing what was already there.
        let additional = tile.makeAdditionalTitleBarMenuItems().map(\.title)
        try expect(
            additional.contains("Zoom") && additional.contains("Sounds"),
            "outer chrome: the tile menu offers \(additional) — the zoom entry is missing or it "
            + "displaced the existing entries"
        )
    }

    // MARK: - 3. Hit targets follow their controls

    private static func checkHitTargetsFollowTheirControls() throws {
        let fixture = try makeTile(named: "ws5-hit", size: NSSize(width: 520, height: 560))
        defer { fixture.window.orderOut(nil) }
        let tile = fixture.tile
        guard let action = tile.qaPageZoomActionButton else {
            throw fail("hit targets: the tile has no primary action button")
        }
        for zoom in steps {
            tile.setPageZoom(zoom)
            settle(tile)
            let bounds = action.bounds
            try expect(
                bounds.width > 0 && bounds.height > 0,
                "@\(zoom.percent)%: the action button collapsed to \(bounds.size)"
            )
            // `NSView.hitTest` takes a point in the RECEIVER'S SUPERVIEW's
            // coordinates, and the tile is flipped while the window's frame view
            // is not — so the point is converted into the superview's space and
            // the superview is asked, exactly as AppKit asks it on a real click.
            guard let host = tile.superview else {
                throw fail("hit targets: the tile is not in a window")
            }
            let centre = action.convert(NSPoint(x: bounds.midX, y: bounds.midY), to: host)
            let hit = host.hitTest(centre)
            let landedOnAction = hit === action
                || (hit.map { descendants(of: action).contains($0) } ?? false)
            try expect(
                landedOnAction,
                "@\(zoom.percent)%: a click at the action button's own centre hit "
                + "\(hit.map { String(describing: type(of: $0)) } ?? "nothing") instead — the drawn "
                + "control and its hit rect have drifted apart"
            )
            // The control must remain usable at the small end, not merely present.
            try expect(
                bounds.height >= 20,
                "@\(zoom.percent)%: the action button is \(bounds.height)pt tall, below the usable floor"
            )
        }
    }

    // MARK: - 3b. The measurement key itself carries the rung

    /// The audit's named false-green risk, witnessed directly on the production
    /// cache and the production renderer registry.
    ///
    /// It has to be measured at ONE FIXED WIDTH. Through the tile, two rungs also
    /// produce two different content insets and therefore two different width
    /// buckets, so the heights differ whether or not the rung is in the key —
    /// the width coincidence hides a missing scale bucket completely. Holding
    /// the width still removes that cover: if `contentSizePolicy` were left at
    /// its `.standard` default, the second measurement would be a cache HIT and
    /// would return the first rung's height.
    private static func checkTheMeasurementKeyCarriesTheRung() throws {
        let cache = AgentBlockMeasurementCache()
        let registry = AgentBlockRendererRegistry.production
        let block = AgentBlock(
            id: nodeID("ws5-key-probe"), revision: 1, kind: .paragraph,
            payload: .paragraph([.text(String(repeating:
                "A paragraph long enough that its height depends on the type size. ", count: 6))]))
        let renderer = try registry.renderer(for: block.kind, entryRole: .assistant)
        let width: CGFloat = 400

        func measure(_ zoom: AgentPageZoom) -> CGFloat {
            var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
            context.pageZoom = zoom
            return cache.height(
                for: block, width: width, context: context, entryRole: .assistant,
                contentSizePolicy: AgentContentSizePolicy(scaleBucket: zoom.percent),
                renderer: renderer)
        }

        let atHundred = measure(.default)
        try expect(cache.measurementMissCount == 1, "the first measurement was not a miss")
        let atOneFifty = measure(AgentPageZoom(percent: 150))
        try expect(
            cache.measurementMissCount == 2,
            "measuring the SAME block at the SAME width but a different rung was a cache HIT — the "
            + "scale bucket is missing from the measurement key"
        )
        try expect(
            atOneFifty > atHundred,
            "at a fixed width, 150% did not measure taller than 100% (\(atHundred) -> \(atOneFifty))"
        )
        // …and the first rung's height is still there, unharmed.
        try expect(
            measure(.default) == atHundred && cache.measurementMissCount == 2,
            "re-measuring 100% after 150% re-measured or returned a different height"
        )
        let atEighty = measure(AgentPageZoom(percent: 80))
        try expect(
            atEighty < atHundred && cache.measurementMissCount == 3,
            "80% did not measure shorter than 100% at a fixed width (\(atEighty) vs \(atHundred))"
        )
    }

    // MARK: - 4. Measurement invalidation: exactly once, then steady

    private static func checkMeasurementInvalidatesOncePerRungAndIsSteadyOtherwise() throws {
        let fixture = try makeTile(named: "ws5-cache", size: NSSize(width: 520, height: 560))
        defer { fixture.window.orderOut(nil) }
        let tile = fixture.tile
        guard let transcript = tile.qaTranscriptForChecks else { throw fail("cache: no transcript") }

        // Warm the 100% bucket.
        _ = transcript.qaMeasuredRowHeights()
        settle(tile)

        // Steady state at a fixed rung: repeated layout and prepare must add no
        // measurement and no real prepare pass.
        var missesBefore = transcript.qaMeasurementMissCount
        var preparesBefore = transcript.qaLayoutPreparePassCount
        for _ in 0..<10 {
            _ = transcript.qaMeasuredRowHeights()
            settle(tile)
        }
        try expect(
            transcript.qaMeasurementMissCount == missesBefore,
            "steady state at 100%: ten repeats added "
            + "\(transcript.qaMeasurementMissCount - missesBefore) measurements"
        )
        try expect(
            transcript.qaLayoutPreparePassCount == preparesBefore,
            "steady state at 100%: ten repeats added "
            + "\(transcript.qaLayoutPreparePassCount - preparesBefore) real prepare passes"
        )

        // One rung change: measurement MUST be redone (the heights are different)
        // and the prepared geometry MUST be recomputed (the fast path must not
        // early-return on an unchanged width bucket, signature and row count).
        missesBefore = transcript.qaMeasurementMissCount
        preparesBefore = transcript.qaLayoutPreparePassCount
        let transitionsBefore = transcript.qaPageZoomTransitionCount
        tile.setPageZoom(AgentPageZoom(percent: 150))
        settle(tile)
        _ = transcript.qaMeasuredRowHeights()
        try expect(
            transcript.qaPageZoomTransitionCount == transitionsBefore + 1,
            "a rung change must push exactly one transition through the transcript, got "
            + "\(transcript.qaPageZoomTransitionCount - transitionsBefore)"
        )
        try expect(
            transcript.qaMeasurementMissCount > missesBefore,
            "a rung change measured nothing new — the cache aliased the 100% heights"
        )
        try expect(
            transcript.qaLayoutPreparePassCount > preparesBefore,
            "a rung change did not recompute the prepared geometry — the layout fast path "
            + "early-returned because its identity omits the rung"
        )

        // …and then it is steady again at the NEW rung.
        missesBefore = transcript.qaMeasurementMissCount
        preparesBefore = transcript.qaLayoutPreparePassCount
        for _ in 0..<10 {
            _ = transcript.qaMeasuredRowHeights()
            settle(tile)
        }
        try expect(
            transcript.qaMeasurementMissCount == missesBefore,
            "steady state at 150%: ten repeats added "
            + "\(transcript.qaMeasurementMissCount - missesBefore) measurements"
        )
        try expect(
            transcript.qaLayoutPreparePassCount == preparesBefore,
            "steady state at 150%: ten repeats added "
            + "\(transcript.qaLayoutPreparePassCount - preparesBefore) real prepare passes"
        )

        // Returning to a rung the reader has already visited must cost NO new
        // measurement. This is the assertion that gives the scale bucket in the
        // measurement key its teeth: if the key omitted the rung, the 150%
        // heights would have overwritten the 100% ones and coming back would
        // either re-measure or (worse) return the wrong heights.
        let heightsAt150 = transcript.qaMeasuredRowHeights()
        tile.setPageZoom(.default)
        settle(tile)
        let heightsBackAt100 = transcript.qaMeasuredRowHeights()
        try expect(
            heightsBackAt100 != heightsAt150,
            "returning to 100% produced the same row heights as 150% — the rung is not in the "
            + "measurement identity"
        )
        missesBefore = transcript.qaMeasurementMissCount
        tile.setPageZoom(AgentPageZoom(percent: 150))
        settle(tile)
        try expect(
            transcript.qaMeasuredRowHeights() == heightsAt150,
            "revisiting 150% produced different heights than the first visit"
        )
        try expect(
            transcript.qaMeasurementMissCount == missesBefore,
            "revisiting a rung re-measured \(transcript.qaMeasurementMissCount - missesBefore) rows "
            + "— the cached measurements for that rung were thrown away"
        )

        // Re-asserting the SAME rung is inert: no apply, no transition, no work.
        let appliesBefore = tile.qaPageZoomApplyCount
        missesBefore = transcript.qaMeasurementMissCount
        try expect(
            !tile.setPageZoom(AgentPageZoom(percent: 150)),
            "setting the current rung again reported a change"
        )
        try expect(
            tile.qaPageZoomApplyCount == appliesBefore
                && transcript.qaMeasurementMissCount == missesBefore,
            "setting the current rung again did work anyway"
        )

        // An end stop is inert too, through the real command path.
        try expect(
            !tile.performPageZoomCommand(.zoomIn),
            "zoom-in at 150% reported a change"
        )
        try expect(
            tile.pageZoom.percent == 150,
            "zoom-in at 150% moved the rung to \(tile.pageZoom.percent)"
        )
    }

    // MARK: - 5. Reader state survives a rung change

    private static func checkReaderStateSurvivesAZoom() throws {
        let fixture = try makeTile(named: "ws5-reader", size: NSSize(width: 520, height: 420))
        defer { fixture.window.orderOut(nil) }
        let tile = fixture.tile
        guard let transcript = tile.qaTranscriptForChecks,
              let composer = tile.qaPageZoomComposerView else {
            throw fail("reader state: the tile has no transcript or composer")
        }

        // Composer: text, selection and focus.
        composer.textView.string = "a draft the reader is in the middle of writing"
        let selection = NSRange(location: 2, length: 6)
        composer.textView.setSelectedRange(selection)
        fixture.window.makeFirstResponder(composer.textView)
        let wasFirstResponder = fixture.window.firstResponder === composer.textView
        try expect(wasFirstResponder, "reader state: the composer never took first responder")

        // A tool disclosure the reader opened.
        transcript.qaSetDisclosureState(for: nodeID("ws5-tool"), expanded: true)
        settle(tile)
        try expect(
            transcript.qaDisclosureState(for: nodeID("ws5-tool")) == true,
            "reader state: the disclosure did not open"
        )

        // Park the reader mid-document so there IS an anchor to preserve.
        let scrollView = transcript.qaScrollViewForChecks
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: documentHeight * 0.4))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(tile)
        guard let anchorBefore = transcript.qaTopSemanticID else {
            throw fail("reader state: no semantic row is under the reader's viewport top")
        }
        let offsetBefore = transcript.qaTopSemanticOffset ?? 0

        tile.setPageZoom(AgentPageZoom(percent: 125))
        settle(tile)

        try expect(
            transcript.qaTopSemanticID == anchorBefore,
            "reader state: the row under the viewport top changed from "
            + "\(anchorBefore.rawValue) to \(transcript.qaTopSemanticID?.rawValue ?? "nothing")"
        )
        let offsetAfter = transcript.qaTopSemanticOffset ?? 0
        // The anchored row's own height changes with the rung, so the offset is
        // allowed to move by at most the growth of one row.
        try expect(
            abs(offsetAfter - offsetBefore) <= 24,
            "reader state: the anchored row drifted \(offsetAfter - offsetBefore)pt under the viewport top"
        )
        try expect(
            composer.textView.string == "a draft the reader is in the middle of writing",
            "reader state: the composer's text changed to '\(composer.textView.string)'"
        )
        try expect(
            composer.textView.selectedRange() == selection,
            "reader state: the composer's selection moved to \(composer.textView.selectedRange())"
        )
        try expect(
            fixture.window.firstResponder === composer.textView,
            "reader state: the composer lost first responder"
        )
        try expect(
            transcript.qaDisclosureState(for: nodeID("ws5-tool")) == true,
            "reader state: the open disclosure closed"
        )
        // Positive control for this whole section.
        try expect(
            transcript.qaPageZoomTransitionCount > 0 && tile.qaPageZoomScaledViewCount > 0,
            "reader state: the rung never reached the content, so nothing was preserved through anything"
        )
        // …and the content really did reflow while all of that held.
        try expect(
            composer.textView.font.map { $0.pointSize > CGFloat(Typography.style(for: .body).size) }
                ?? false,
            "reader state: the composer text kept its 100% font at 125%"
        )
    }

    // MARK: - 6. Tail-follow survives a rung change mid-stream

    private static func checkTailFollowSurvivesAZoomDuringStreaming() throws {
        let fixture = try makeTile(named: "ws5-tail", size: NSSize(width: 520, height: 380))
        defer { fixture.window.orderOut(nil) }
        let tile = fixture.tile
        guard let transcript = tile.qaTranscriptForChecks else { throw fail("tail: no transcript") }

        // Pin the reader to the bottom, as a live turn does.
        transcript.jumpToLatest()
        settle(tile)
        try expect(transcript.qaIsNearBottom, "tail: the reader is not at the bottom to begin with")
        try expect(!transcript.qaShowsJumpToLatest, "tail: jump-to-latest is offered while pinned")

        tile.setPageZoom(AgentPageZoom(percent: 150))
        settle(tile)
        try expect(
            transcript.qaIsNearBottom,
            "tail: a rung change dropped the reader off the bottom of a live transcript"
        )

        // A streaming append AFTER the rung change must still land at the new
        // rung's metrics and must still keep the reader pinned.
        let base = transcript.qaAppliedVersion
        var (document, _) = fixtureDocument(version: base + 1)
        let appended = AgentBlock(
            id: nodeID("ws5-stream"), revision: 1, kind: .paragraph,
            payload: .paragraph([.text(String(repeating: "streamed continuation. ", count: 10))]))
        var entries = document.entries
        entries[entries.count - 1].blocks.append(appended)
        entries[entries.count - 1].revision += 1
        document = AgentDocument(version: base + 1, entries: entries)
        try transcript.apply(
            document: document,
            patch: try AgentDocumentPatch(
                fromVersion: base, toVersion: base + 1, inserted: [appended.id]))
        settle(tile)
        try expect(
            transcript.qaLayoutPageZoomPercent == 150,
            "tail: a streaming append reset the layout's rung to \(transcript.qaLayoutPageZoomPercent)%"
        )
        try expect(
            transcript.qaIsNearBottom,
            "tail: a streaming append after a rung change lost the tail"
        )
    }

    // MARK: - 7. The menu

    private static func checkMenuOffersTheRungAndDisablesTheEndStops() throws {
        let fixture = try makeTile(named: "ws5-menu", size: NSSize(width: 520, height: 480))
        defer { fixture.window.orderOut(nil) }
        let tile = fixture.tile

        for zoom in steps {
            tile.setPageZoom(zoom)
            let entries = tile.qaPageZoomMenuEntries()
            let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            guard let readout = byID["agentTile.pageZoom.readout"] else {
                throw fail("@\(zoom.percent)%: the menu offers no percentage readout")
            }
            try expect(
                readout.title.contains(zoom.displayPercentage),
                "@\(zoom.percent)%: the readout says '\(readout.title)'"
            )
            for command in AgentPageZoomCommand.allCases {
                guard let item = byID["agentTile.pageZoom.\(command.rawValue)"] else {
                    throw fail("@\(zoom.percent)%: the menu offers no \(command.rawValue) item")
                }
                try expect(
                    item.enabled == command.isEnabled(for: zoom),
                    "@\(zoom.percent)%: \(command.rawValue) is "
                    + "\(item.enabled ? "enabled" : "disabled") but should be the other"
                )
            }
        }

        // The menu items are wired to a target that actually moves the rung.
        tile.setPageZoom(.default)
        try expect(
            tile.qaInvokePageZoomMenuItem("agentTile.pageZoom.zoomIn"),
            "the Zoom In menu item has no target/action"
        )
        try expect(tile.pageZoom.percent == 110, "the Zoom In menu item landed on \(tile.pageZoom.percent)")
        try expect(
            tile.qaInvokePageZoomMenuItem("agentTile.pageZoom.reset"),
            "the Actual Size menu item has no target/action"
        )
        try expect(tile.pageZoom.percent == 100, "Actual Size landed on \(tile.pageZoom.percent)")

        // A DISABLED item must be inert even if it is invoked anyway.
        tile.setPageZoom(AgentPageZoom(percent: 80))
        _ = tile.qaInvokePageZoomMenuItem("agentTile.pageZoom.zoomOut")
        try expect(
            tile.pageZoom.percent == 80,
            "invoking the disabled Zoom Out item at 80% moved the rung to \(tile.pageZoom.percent)"
        )
    }

    // MARK: - 8. Shortcut routing on real NSEvents

    private static func checkShortcutRoutingOnRealEvents() throws {
        let fixture = try makeTile(named: "ws5-keys", size: NSSize(width: 520, height: 480))
        defer { fixture.window.orderOut(nil) }
        let tile = fixture.tile

        func event(
            _ characters: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags
        ) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: ignoring,
                isARepeat: false, keyCode: 0)!
        }

        struct Case { let name: String; let event: NSEvent; let consumed: Bool; let expected: Int }
        tile.setPageZoom(.default)
        let cases: [Case] = [
            Case(name: "Command-equal", event: event("=", "=", [.command]), consumed: true, expected: 110),
            Case(name: "Command-Shift-equal", event: event("+", "=", [.command, .shift]),
                 consumed: true, expected: 125),
            Case(name: "Command-plus (unshifted layout)", event: event("+", "+", [.command]),
                 consumed: true, expected: 150),
            Case(name: "Command-equal at the ceiling", event: event("=", "=", [.command]),
                 consumed: true, expected: 150),
            Case(name: "Command-hyphen", event: event("-", "-", [.command]), consumed: true, expected: 125),
            Case(name: "Command-zero", event: event("0", "0", [.command]), consumed: true, expected: 100),
            // Caps Lock must not disqualify a chord — AppKit sets it independently.
            Case(name: "Command-equal with Caps Lock",
                 event: event("=", "=", [.command, .capsLock]), consumed: true, expected: 110),
            // Everything else falls through, unchanged.
            Case(name: "Command-C", event: event("c", "c", [.command]), consumed: false, expected: 110),
            Case(name: "Command-A", event: event("a", "a", [.command]), consumed: false, expected: 110),
            Case(name: "Option-Command-equal", event: event("=", "=", [.command, .option]),
                 consumed: false, expected: 110),
            Case(name: "Control-Command-hyphen", event: event("-", "-", [.command, .control]),
                 consumed: false, expected: 110),
            Case(name: "bare equal", event: event("=", "=", []), consumed: false, expected: 110),
            Case(name: "bare zero", event: event("0", "0", []), consumed: false, expected: 110),
            Case(name: "Command-1", event: event("1", "1", [.command]), consumed: false, expected: 110),
        ]
        for testCase in cases {
            let consumed = tile.handlePageZoomKeyEquivalent(with: testCase.event)
            try expect(
                consumed == testCase.consumed,
                "\(testCase.name): \(consumed ? "consumed" : "fell through") but should have "
                + "\(testCase.consumed ? "been consumed" : "fallen through")"
            )
            try expect(
                tile.pageZoom.percent == testCase.expected,
                "\(testCase.name): the rung is \(tile.pageZoom.percent)%, expected \(testCase.expected)%"
            )
        }
    }

    // MARK: - 9. Two tiles, two rungs, no bleed

    private static func checkTwoTilesHoldDifferentRungs() throws {
        let size = NSSize(width: 520, height: 500)
        let a = try makeTile(named: "ws5-tile-a", size: size)
        let b = try makeTile(named: "ws5-tile-b", size: size)
        defer { a.window.orderOut(nil); b.window.orderOut(nil) }

        a.tile.setPageZoom(AgentPageZoom(percent: 150))
        b.tile.setPageZoom(AgentPageZoom(percent: 80))
        settle(a.tile)
        settle(b.tile)

        try expect(a.tile.pageZoom.percent == 150, "tile A drifted to \(a.tile.pageZoom.percent)%")
        try expect(b.tile.pageZoom.percent == 80, "tile B drifted to \(b.tile.pageZoom.percent)%")

        let fontsA = stableFontSizes(a.tile)
        let fontsB = stableFontSizes(b.tile)
        try expect(
            fontsA != fontsB,
            "two tiles at 150% and 80% resolved IDENTICAL font sizes — the rung is shared, not per tile"
        )
        try expect(
            zip(fontsA, fontsB).allSatisfy { $0 > $1 },
            "the 150% tile is not uniformly larger than the 80% tile: \(fontsA) vs \(fontsB)"
        )
        try expect(
            a.tile.qaPageZoomHeaderHeightConstant > b.tile.qaPageZoomHeaderHeightConstant,
            "both tiles solved the same header height"
        )
        guard let transcriptA = a.tile.qaTranscriptForChecks,
              let transcriptB = b.tile.qaTranscriptForChecks else {
            throw fail("two tiles: a transcript is missing")
        }
        try expect(
            transcriptA.qaMeasuredRowHeights().reduce(0, +)
                > transcriptB.qaMeasuredRowHeights().reduce(0, +),
            "both transcripts measured the same total height at different rungs"
        )

        // Moving A must not touch B — including B's cached measurements.
        let bMissesBefore = transcriptB.qaMeasurementMissCount
        let bHeightsBefore = transcriptB.qaMeasuredRowHeights()
        let bFontsBefore = fontsB
        a.tile.setPageZoom(AgentPageZoom(percent: 90))
        settle(a.tile)
        settle(b.tile)
        try expect(b.tile.pageZoom.percent == 80, "moving tile A moved tile B to \(b.tile.pageZoom.percent)%")
        try expect(
            transcriptB.qaMeasuredRowHeights() == bHeightsBefore,
            "moving tile A changed tile B's measured row heights"
        )
        try expect(
            stableFontSizes(b.tile) == bFontsBefore,
            "moving tile A changed tile B's resolved fonts"
        )
        try expect(
            transcriptB.qaMeasurementMissCount == bMissesBefore,
            "moving tile A made tile B re-measure "
            + "\(transcriptB.qaMeasurementMissCount - bMissesBefore) rows"
        )
    }

    // MARK: - 10. Nothing persists; recreation resets

    private static func checkNothingIsPersistedAndRecreationResets() throws {
        let model = Tile(
            id: UUID(),
            kind: .managedAgent,
            title: "ws5-persistence",
            frame: TileFrame(x: 12, y: 34, width: 520, height: 480),
            zPosition: .fromLegacyRank(3),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        )
        var canvas = CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [model], groups: [], lastActiveTileId: model.id)
        let viewportBefore = canvas.viewport
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canvasBefore = try encoder.encode(canvas)
        let modelBefore = try encoder.encode(model)

        let defaults = UserDefaults.standard
        func zoomNamedDefaults() -> [String: String] {
            defaults.dictionaryRepresentation()
                .filter { $0.key.lowercased().contains("zoom") }
                .mapValues { String(describing: $0) }
        }
        let defaultsBefore = zoomNamedDefaults()

        let view = ManagedAgentTileNSView(tile: model)
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 480)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        settle(view)

        try expect(view.pageZoom.percent == 100, "a fresh tile did not start at 100%")

        for zoom in steps { view.setPageZoom(zoom); settle(view) }
        view.setPageZoom(AgentPageZoom(percent: 150))
        settle(view)
        try expect(view.qaPageZoomApplyCount > 0, "persistence: no rung was ever applied")

        canvas.tiles = [view.tile]
        try expect(
            try encoder.encode(view.tile) == modelBefore,
            "persistence: the Tile model changed after zooming — a rung reached tile metadata"
        )
        try expect(
            try encoder.encode(canvas) == canvasBefore,
            "persistence: the canvas JSON changed after zooming"
        )
        let canvasJSON = String(data: try encoder.encode(canvas), encoding: .utf8) ?? ""
        try expect(
            !canvasJSON.lowercased().contains("pagezoom"),
            "persistence: the canvas JSON names a page zoom"
        )
        try expect(
            canvas.viewport == viewportBefore,
            "persistence: the CANVAS CAMERA moved — page zoom is not canvas zoom"
        )
        try expect(
            zoomNamedDefaults() == defaultsBefore,
            "persistence: a zoom-named user default appeared or changed"
        )

        // A recreated tile — the same MODEL, a new view — starts at 100%.
        let recreated = ManagedAgentTileNSView(tile: view.tile)
        try expect(
            recreated.pageZoom.percent == 100,
            "a recreated tile came back at \(recreated.pageZoom.percent)% — the rung survived teardown"
        )
        try expect(
            recreated.qaPageZoomApplyCount == 0,
            "a recreated tile had already applied a rung"
        )
    }
}
