import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import CryptoKit

/// A labelled contact sheet of the agent surfaces, in both appearances, written
/// to `qa-runs/<timestamp>/tour/` with an `index.md` that names every parameter
/// of every image.
///
/// **Advisory only — it asserts nothing about how anything looks.** Its job is to
/// make each render self-describing. The worst QA failure of the previous run was
/// judging a 460pt fixture in an unknown appearance and calling it clean: nothing
/// in the artifact said how wide it was or which appearance produced it, so an
/// obviously-wrong render read as fine. Every filename here carries
/// surface · state · size · appearance, and `index.md` repeats them in a table.
///
/// It never gates: `run-matrix.sh` captures this leg's exit status and reports it
/// rather than propagating it, so a tour failure cannot turn the matrix red.
/// Belt and braces, there is no visual assertion in this file either, so a
/// non-zero exit can only mean something mechanical broke — a surface fixture
/// vanished, a render threw, or the artifacts could not be written. Both halves
/// exist for the same reason: if a screenshot can fail the build, people start
/// fixing screenshots instead of bugs.
@MainActor
enum UITourCheck {
    struct TourError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func fail(_ message: String) -> TourError { TourError(message: message) }

    // MARK: - Matrix

    /// The width sweep: the tile minimum (the width the packet calls "320" — read
    /// from `TileGeometry` rather than hardcoded, same as
    /// `UIProbeGeometry.probeWidths`), then two roomier ones.
    ///
    /// Applied to the two surfaces whose layout actually depends on width — the
    /// managed-agent tile and the transcript cards, which is where the half-width
    /// column bug lived. Status chips, the sidebar and settings are fixed-width
    /// chrome: a sidebar at 900pt is not a case that occurs, and the packet's
    /// ~40-image ceiling exists so the sheet stays scannable, since the full cross
    /// product would be ~100 images nobody reads. Every surface's filename carries
    /// its size either way.
    static let tileWidths: [Double] = [TileGeometry.minimumSize(for: .managedAgent).width, 640, 900]

    static let tileHeight: Double = 560
    static let transcriptReviewWidths: [Double] = [320, 480, 640, 900]
    static let transcriptReviewHeight: Double = 720

    static let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    /// The managed-agent tile states. `long-transcript` is deliberately included:
    /// overflow and scroll are where this layout actually breaks.
    enum TileState: String, CaseIterable {
        case ready
        case working
        case withApproval = "with-approval"
        case longTranscript = "long-transcript"
    }

    /// One planned render.
    struct Shot {
        let surface: String
        let state: String
        let size: NSSize
        let appearance: NSAppearance.Name
        let scale: CGFloat
        let make: () -> NSView

        init(
            surface: String,
            state: String,
            size: NSSize,
            appearance: NSAppearance.Name,
            scale: CGFloat = UIProbe.renderScale,
            make: @escaping () -> NSView
        ) {
            self.surface = surface
            self.state = state
            self.size = size
            self.appearance = appearance
            self.scale = scale
            self.make = make
        }

        var fileName: String {
            let scaleSuffix = scale == UIProbe.renderScale ? "" : "-\(Int(scale))x"
            return "\(surface)-\(state)-\(Int(size.width))x\(Int(size.height))-\(UITourCheck.shortName(appearance))\(scaleSuffix).png"
        }
    }

    nonisolated static func shortName(_ appearance: NSAppearance.Name) -> String {
        appearance == .aqua ? "aqua" : "darkAqua"
    }

    // MARK: - Surfaces

    /// A managed-agent tile in `state`, built at `size` so the transcript lays
    /// out against the real probe geometry.
    ///
    /// Reuses `LabCatalog.managedAgentFixtureEvents` — the same canned event
    /// stream the Component Lab card and every phase-0 gate render — so the tour
    /// shows what the gates measured, not a second private fixture that could
    /// drift away from it.
    static func makeTile(state: TileState, size: NSSize) -> ManagedAgentTileNSView {
        let tile = Tile(
            // Fixed, so two runs of the tour produce comparable images.
            id: UUID(uuidString: "71000000-0000-4000-8000-0000000000\(String(format: "%02d", TileState.allCases.firstIndex(of: state)! + 80))")!,
            kind: .managedAgent,
            title: "Claude - feature/login",
            frame: TileFrame(x: 0, y: 0, width: size.width, height: size.height),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        )
        let view = ManagedAgentTileNSView(tile: tile)
        view.frame = NSRect(origin: .zero, size: size)

        switch state {
        case .ready:
            // Session up, nothing asked of it yet — the state a freshly spawned
            // agent sits in, and the one most likely to render as an empty box.
            //
            // `.ready`, not `.running`: `deriveAgentStatus` reads a running
            // session as `.working`, so `.running` here would render a "working"
            // chip over an empty transcript — a shot that contradicts its own
            // label. `.ready` falls through the derivation to `.idle`, which is
            // what a spawned-but-unasked agent actually is, and it comes from the
            // real event stream rather than a pinned status.
            view.ingest(.sessionStateChanged(.ready))
        case .working:
            for event in LabCatalog.managedAgentFixtureEvents(includeApproval: false) { view.ingest(event) }
        case .withApproval:
            for event in LabCatalog.managedAgentFixtureEvents(includeApproval: true) { view.ingest(event) }
        case .longTranscript:
            for event in LabCatalog.managedAgentFixtureEvents(includeApproval: false) { view.ingest(event) }
            // The geometry gate's own overflow fixture, reused rather than
            // re-invented: `UIProbeGeometry` asserts these prompts overflow the
            // clip view at every probe width, and they are short on purpose (a
            // single 2000-character line hides a half-width column, because an
            // over-wide row is clamped back to full width anyway). Reusing it
            // means the tour cannot drift into showing a different overflow case
            // than the one the gate measures.
            for prompt in UIProbeGeometry.scrollWitnessPrompts { view.appendUserPrompt(prompt) }
        }
        return view
    }

    static func makeSemanticTranscript(
        state: AgentTranscriptReviewState,
        size: NSSize,
        appearance: NSAppearance.Name
    ) -> AgentTranscriptReviewSurface {
        LabCatalog.makeTranscriptReviewSurface(
            state: state,
            size: size,
            theme: appearance == .darkAqua ? .dark : .light
        )
    }

    /// Raw provider fixtures rendered through the production translators and
    /// transcript projection. This is QA-only evidence, but it deliberately
    /// avoids a hand-authored provider lookalike.
    static func makeProviderTranscript(provider: String, size: NSSize, appearance: NSAppearance.Name) -> NSView {
        let claude = [
            #"{"type":"system","subtype":"init","session_id":"visual","cwd":"/fixture"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Inspect the typed file detail."}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"The transcript keeps one aligned semantic column."}},"parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"read","name":"Read","input":{"file_path":"Sources/Agent.swift"}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"read","is_error":false,"content":"ok"}]},"parent_tool_use_id":null}"#,
        ]
        let codex = [
            #"{"type":"thread.started","thread_id":"visual"}"#, #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"reason","type":"reasoning","text":"Inspect the typed file detail."}}"#,
            #"{"type":"item.completed","item":{"id":"answer","type":"agent_message","text":"The transcript keeps one aligned semantic column."}}"#,
            #"{"type":"item.started","item":{"id":"read","type":"file_change","changes":[{"path":"Sources/Agent.swift","kind":"update"}],"status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"read","type":"file_change","changes":[{"path":"Sources/Agent.swift","kind":"update"}],"status":"completed"}}"#,
        ]
        let pi = [
            #"{"type":"session","id":"visual","cwd":"/fixture"}"#, #"{"type":"agent_start"}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"Inspect the typed file detail."}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"The transcript keeps one aligned semantic column."}}"#,
            #"{"type":"tool_execution_start","toolCallId":"read","toolName":"read","args":{"path":"Sources/Agent.swift"}}"#,
            #"{"type":"tool_execution_end","toolCallId":"read","toolName":"read","isError":false}"#,
        ]
        let events: [AgentRuntimeEvent]
        switch provider {
        case "claude": var translator = ClaudeEventTranslator(runToken: "visual"); events = translator.translate(stream: claude)
        case "codex": var translator = CodexEventTranslator(runToken: "visual"); events = translator.translate(stream: codex)
        default: var translator = PiEventTranslator(); events = translator.translate(stream: pi)
        }
        var projection = AgentTranscriptProjection(threadId: "visual-thread")
        try? projection.appendUserPrompt(id: AgentNodeID(rawValue: "visual-\(provider)-user")!, text: "Review the transcript detail and report the result.")
        for event in events { projection.ingest(event.withThreadId("visual-thread")) }
        let list = AgentTranscriptListView(renderContext: AgentRenderContext(
            actions: .disabled, tokens: .transcript, appearance: appearance == .darkAqua ? .dark : .light
        ))
        list.frame = NSRect(origin: .zero, size: size)
        let document = AgentDocument(version: 1, entries: projection.document.entries)
        try? list.apply(document: document, patch: AgentDocumentPatch(
            fromVersion: 0, toVersion: 1, inserted: document.entries.flatMap(\.blocks).map(\.id)
        ))
        return list
    }

    /// `.plans/45` — the transcript AFTER the reader opens things. Dylan's
    /// review found both defects that only exist in this state: reasoning rows
    /// that expand without remeasuring, and folded tool runs whose expanded
    /// members are indistinguishable from ungrouped rows. A still of the
    /// collapsed surface cannot show either.
    static func makeExpandedSemanticTranscript(
        state: AgentTranscriptReviewState,
        size: NSSize,
        appearance: NSAppearance.Name
    ) -> AgentTranscriptReviewSurface {
        let surface = LabCatalog.makeTranscriptReviewSurface(
            state: state,
            size: size,
            theme: appearance == .darkAqua ? .dark : .light
        )
        let host = NSView(frame: surface.frame)
        host.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        surface.transcript.layoutSubtreeIfNeeded()
        surface.transcript.collectionView.layoutSubtreeIfNeeded()
        surface.transcript.qaExpandEverythingForChecks()
        surface.layoutSubtreeIfNeeded()
        surface.transcript.layoutSubtreeIfNeeded()
        surface.transcript.collectionView.layoutSubtreeIfNeeded()
        surface.removeFromSuperview()
        surface.frame = NSRect(origin: .zero, size: size)
        return surface
    }

    static func makePositionedSemanticTranscript(
        state: AgentTranscriptReviewState, position: CGFloat,
        size: NSSize, appearance: NSAppearance.Name
    ) -> AgentTranscriptReviewSurface {
        let surface = makeSemanticTranscript(state: state, size: size, appearance: appearance)
        let host = NSView(frame: surface.frame)
        host.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        surface.transcript.layoutSubtreeIfNeeded()
        surface.transcript.collectionView.layoutSubtreeIfNeeded()
        let clip = surface.transcript.scrollView.contentView
        let maximum = max(0, surface.transcript.collectionView.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: maximum * min(1, max(0, position))))
        surface.transcript.scrollView.reflectScrolledClipView(clip)
        surface.removeFromSuperview()
        surface.frame = NSRect(origin: .zero, size: size)
        return surface
    }

    /// Surfaces the Component Lab already vends, taken from the catalogue by id so
    /// the tour renders the same fixture the lab and the gates do.
    static let labSurfaces: [(surface: String, entryId: String)] = [
        (surface: "status-chips", entryId: "agent.statusChip"),
        (surface: "sidebar", entryId: "chrome.sidebar"),
        (surface: "sidebar", entryId: "chrome.sidebar.live")
    ]

    /// Builds the whole shot list. Order is surface-major so `index.md` reads in
    /// the order a reviewer wants to scan it.
    static func plan() throws -> [Shot] {
        let entries = LabCatalog.entries(env: LabEnvironment(ghostty: nil, browserEngine: nil))
        var shots: [Shot] = []

        for state in TileState.allCases {
            for width in tileWidths {
                let size = NSSize(width: width, height: tileHeight)
                for appearance in appearances {
                    shots.append(Shot(
                        surface: "managed-agent-tile", state: state.rawValue, size: size,
                        appearance: appearance, make: { makeTile(state: state, size: size) }
                    ))
                }
            }
        }

        // P3.12's review set: the complete mixed reading path at every named
        // width, then long/active/failed/approval focus states at the reference
        // width. Every shot is paired across appearances.
        for width in transcriptReviewWidths {
            let size = NSSize(width: width, height: transcriptReviewHeight)
            for appearance in appearances {
                shots.append(Shot(
                    surface: "semantic-transcript", state: AgentTranscriptReviewState.mixed.rawValue,
                    size: size, appearance: appearance,
                    make: { makeSemanticTranscript(state: .mixed, size: size, appearance: appearance) }
                ))
            }
        }
        for provider in ["claude", "codex", "pi"] {
            for width in transcriptReviewWidths {
                let size = NSSize(width: width, height: transcriptReviewHeight)
                for appearance in appearances {
                    shots.append(Shot(
                        surface: "semantic-transcript", state: "actual-\(provider)", size: size,
                        appearance: appearance,
                        make: { makeProviderTranscript(provider: provider, size: size, appearance: appearance) }
                    ))
                }
            }
        }
        for state in [
            AgentTranscriptReviewState.long, .activeTool, .failedTool, .approval,
            // `.plans/45` T2. Advisory PNGs are the review mechanism for the
            // whole visual milestone: the transcript owns no committed baseline
            // and the two image-comparing legs are parked, so before/after tour
            // renders at every width in both appearances are how this work is
            // looked at without blessing anything.
            .headingLadder, .lists, .tableAndBreaks, .errorVsNotice,
            .turnBoundary, .recededWork,
            // `.plans/45` S1. The replayed real capture is what the S7 gallery
            // is judged on — authored states alone hid the rejected milestone.
            .realClaudeTurn,
        ] {
            let size = NSSize(width: 480, height: transcriptReviewHeight)
            for appearance in appearances {
                shots.append(Shot(
                    surface: "semantic-transcript", state: state.rawValue,
                    size: size, appearance: appearance,
                    make: { makeSemanticTranscript(state: state, size: size, appearance: appearance) }
                ))
            }
        }
        // The OPENED transcript. Two of Dylan's four review findings only exist
        // after a click, so the tour has to photograph that state too.
        for state in [AgentTranscriptReviewState.realClaudeTurn, .recededWork] {
            let size = NSSize(width: 480, height: transcriptReviewHeight)
            for appearance in appearances {
                shots.append(Shot(
                    surface: "semantic-transcript", state: "\(state.rawValue)-expanded",
                    size: size, appearance: appearance,
                    make: { makeExpandedSemanticTranscript(state: state, size: size, appearance: appearance) }
                ))
            }
        }
        // WS6 deterministic viewport/state inventory. These are aliases of the
        // production fixtures with the viewport/disclosure state made explicit
        // in the artifact name for review.
        let inventorySize = NSSize(width: 480, height: transcriptReviewHeight)
        for (label, fraction) in [("long-history-top", CGFloat(0)), ("long-history-middle", CGFloat(0.5)), ("long-history-bottom", CGFloat(1))] {
            for appearance in appearances {
                shots.append(Shot(
                    surface: "semantic-transcript", state: label, size: inventorySize, appearance: appearance,
                    make: { makePositionedSemanticTranscript(state: .long, position: fraction, size: inventorySize, appearance: appearance) }
                ))
            }
        }
        for (label, state) in [("lifecycle-active-tool", AgentTranscriptReviewState.activeTool), ("lifecycle-settled-work", .recededWork), ("file-detail-unknown", .mixed)] {
            for appearance in appearances {
                shots.append(Shot(
                    surface: "semantic-transcript", state: label, size: inventorySize, appearance: appearance,
                    make: { makeSemanticTranscript(state: state, size: inventorySize, appearance: appearance) }
                ))
            }
        }

        // P4.10's review set: every composer/choice state at the reference width,
        // plus the multiline full-turn state at 320 pt for the narrow layout.
        // Every shot is paired across appearances.
        for state in AgentComposerReviewState.allCases {
            let size = AgentComposerReviewSurface.preferredSize(for: state)
            for appearance in appearances {
                shots.append(Shot(
                    surface: "composer-review", state: state.rawValue, size: size,
                    appearance: appearance,
                    make: {
                        LabCatalog.makeComposerReviewSurface(
                            state: state, size: size,
                            theme: appearance == .aqua ? .light : .dark
                        )
                    }
                ))
            }
        }
        for appearance in appearances {
            let narrowSize = AgentComposerReviewSurface.preferredSize(for: .multiline, width: 320)
            shots.append(Shot(
                surface: "composer-review", state: "multiline-narrow", size: narrowSize,
                appearance: appearance,
                make: {
                    LabCatalog.makeComposerReviewSurface(
                        state: .multiline, size: narrowSize,
                        theme: appearance == .aqua ? .light : .dark
                    )
                }
            ))
        }

        let throbberSize = ThrobberCandidateGalleryView.preferredSize
        for scale in [CGFloat(1), CGFloat(2)] {
            for appearance in appearances {
                shots.append(Shot(
                    surface: "throbber-candidates",
                    state: "all-phases-\(Int(scale))x",
                    size: throbberSize,
                    appearance: appearance,
                    scale: scale,
                    make: { LabCatalog.makeThrobberCandidateGalleryView(mode: .snapshot) }
                ))
            }
        }

        for lab in labSurfaces {
            guard let entry = entries.first(where: { $0.id == lab.entryId }),
                  case let .staticCard(preferredSize, make) = entry.content else {
                throw fail("missing static Component Lab card '\(lab.entryId)' for tour surface '\(lab.surface)'")
            }
            let size = preferredSize ?? NSSize(width: 560, height: 640)
            for appearance in appearances {
                shots.append(Shot(
                    surface: lab.surface, state: lab.entryId, size: size,
                    appearance: appearance, make: make
                ))
            }
        }

        return shots
    }

    // MARK: - Settings
    //
    // Settings is a launcher, not a static card: `SettingsPanel` owns its own
    // NSPanel. It is rendered on its own path rather than through `UIProbe`
    // because `UIProbe` re-parents the view it is handed, and moving a live
    // panel's `contentView` into another window leaves the panel pointing at a
    // view it no longer contains. So the panel keeps its window, the window is
    // given the requested appearance before it is shown, and the render is taken
    // from the panel's own content view — with the same `effectiveAppearance`
    // assertion `UIProbe` makes, so a settings shot mislabelled `aqua` is still
    // impossible.

    static func renderSettings(appearance name: NSAppearance.Name) throws -> (rep: NSBitmapImageRep, size: NSSize) {
        guard let appearance = NSAppearance(named: name) else {
            throw fail("settings: no NSAppearance named '\(name.rawValue)'")
        }
        // An isolated suite, so a tour render can never write to the real
        // defaults domain (same convention as `SettingsPanel.runSelfCheck`).
        let suiteName = "continuum.uiTour.settings.\(name.rawValue)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw fail("settings: could not create the isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let panel = SettingsPanel(sections: SettingsSchema.sections(), defaults: defaults)
        let appAppearance = NSApp?.appearance
        NSApp?.appearance = appearance
        defer { NSApp?.appearance = appAppearance }

        var result: Result<(NSBitmapImageRep, NSSize), Error>?
        appearance.performAsCurrentDrawingAppearance {
            do {
                panel.show(near: nil)
                guard let content = panel.contentViewForQA else {
                    throw fail("settings: panel has no content view")
                }
                content.window?.appearance = appearance
                content.layoutSubtreeIfNeeded()
                guard content.effectiveAppearance.name == name else {
                    throw fail(
                        "settings: content effectiveAppearance is '\(content.effectiveAppearance.name.rawValue)', requested '\(name.rawValue)'"
                    )
                }
                guard content.bounds.width > 0, content.bounds.height > 0 else {
                    throw fail("settings: content laid out to \(content.bounds.size)")
                }
                guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                    throw fail("settings: could not allocate bitmap")
                }
                content.cacheDisplay(in: content.bounds, to: rep)
                result = .success((rep, content.bounds.size))
            } catch {
                result = .failure(error)
            }
        }
        panel.close()

        switch result {
        case let .success((rep, size)): return (rep, size)
        case let .failure(error): throw error
        case nil: throw fail("settings: drawing-appearance block never ran")
        }
    }

    // MARK: - Output

    static func tourDirectory() throws -> URL {
        if let explicit = ProcessInfo.processInfo.environment["CONTINUUM_UI_TOUR_OUTPUT"], !explicit.isEmpty {
            let directory = URL(fileURLWithPath: explicit, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("tour", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw fail("\(url.lastPathComponent): could not encode PNG")
        }
        try data.write(to: url)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A true one-delta pair: both bitmaps come from the same hosted list and
    /// viewport. A second tail-following list exercises the complementary scroll
    /// policy without changing the photographed non-tail viewport.
    static func writeStreamingDeltaPair(to directory: URL) throws -> [Record] {
        final class Clock: @unchecked Sendable {
            var value: TimeInterval = 10
            func now() -> TimeInterval { value }
        }
        var records: [Record] = []
        var semanticPairs: [[String: Any]] = []
        for appearance in appearances {
            let size = NSSize(width: 480, height: transcriptReviewHeight)
            let clock = Clock()
            var projection = AgentTranscriptProjection(
                threadId: "streaming-visual", monotonicNow: clock.now,
                wallClockNow: { Date(timeIntervalSince1970: 1_700_000_000) }
            )
            for index in 0..<12 {
                _ = try projection.appendUserPrompt(
                    id: AgentNodeID(rawValue: "streaming-history-\(index)")!,
                    text: "History turn \(index): preserve the semantic anchor while one streamed delta lands."
                )
            }
            projection.ingest(.itemStarted(
                threadId: "streaming-visual", itemId: "stable-tool",
                kind: .commandExecution, title: "Stable disclosure"
            ))
            projection.ingest(.itemCompleted(
                threadId: "streaming-visual", itemId: "stable-tool",
                kind: .commandExecution, status: .completed
            ))
            projection.ingest(.turnStarted(threadId: "streaming-visual", turnId: "stream-turn"))
            projection.ingest(.contentDelta(
                threadId: "streaming-visual", turnId: "stream-turn",
                streamKind: .assistant,
                delta: "Streaming response ready.\n\nContext remains stable above the update.\n\nThis final streaming paragraph is deliberately long enough to wrap across several visible lines while the reader viewport remains outside the forty-eight point tail-follow threshold, preserving a real semantic anchor during the update"
            ))
            clock.value += 1
            projection.ingest(.contentDelta(
                threadId: "streaming-visual", turnId: "stream-turn",
                streamKind: .assistant, delta: " ready"
            ))
            _ = projection.flushPendingStreamingMarkup()
            _ = projection.drainTouchedNodes()
            let initial = projection.document
            let initialViewDocument = AgentDocument(version: 1, entries: initial.entries)
            let initialIDs = initial.entries.flatMap { [$0.id] + $0.blocks.map(\.id) }
            let initialBlockIDs = initial.entries.flatMap(\.blocks).map(\.id)
            guard let disclosureID = initial.entries.first(where: {
                if case let .providerItem(_, itemID) = $0.provenance { return itemID == "stable-tool" }
                return false
            })?.blocks.first?.id else { throw fail("streaming pair lacks stable disclosure block") }
            let list = AgentTranscriptListView(renderContext: AgentRenderContext(
                actions: .disabled, tokens: .transcript,
                appearance: appearance == .darkAqua ? .dark : .light
            ))
            list.frame = NSRect(origin: .zero, size: size)
            list.qaRetainHostForEverySemanticRow = true
            try list.apply(
                document: initialViewDocument,
                patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: initialBlockIDs)
            )
            let probe = try UIProbe.render(
                UIProbe.Spec(id: "streaming-delta-pair", size: size, appearance: appearance),
                make: { list }
            )
            list.layoutSubtreeIfNeeded(); list.collectionView.layoutSubtreeIfNeeded()
            let clip = list.scrollView.contentView
            list.qaSetDisclosureState(for: disclosureID, expanded: true)
            list.jumpToLatest()
            let beforeTailOffset = clip.bounds.minY
            clip.scroll(to: NSPoint(x: 0, y: max(0, beforeTailOffset - 56)))
            list.scrollView.reflectScrolledClipView(clip)
            list.layoutSubtreeIfNeeded(); list.collectionView.layoutSubtreeIfNeeded()
            let beforeOffset = clip.bounds.minY
            let beforeDistanceToTail = beforeTailOffset - beforeOffset
            let selectionIndex = IndexPath(item: 11, section: 0)
            let streamIndex = IndexPath(item: initialBlockIDs.count - 1, section: 0)
            let anchorNodeID = initial.entries[11].blocks[0].id
            guard let beforeAnchorFrame = list.collectionView.layoutAttributesForItem(at: selectionIndex)?.frame,
                  let beforeStreamFrame = list.collectionView.layoutAttributesForItem(at: streamIndex)?.frame,
                  beforeStreamFrame.intersects(clip.bounds), beforeDistanceToTail > 2 else {
                throw fail("streaming pair viewport missing stream/non-tail: clip=\(clip.bounds) tail=\(beforeTailOffset) distance=\(beforeDistanceToTail) stream=\(String(describing: list.collectionView.layoutAttributesForItem(at: streamIndex)?.frame))")
            }
            list.collectionView.selectionIndexPaths = [selectionIndex]
            let beforeSelection = list.collectionView.selectionIndexPaths
            let beforeAnchorY = beforeAnchorFrame.minY - beforeOffset
            let beforeRep = try UIProbe.bitmap(of: probe.host, id: "streaming-delta-before")

            clock.value += 1
            projection.ingest(.contentDelta(
                threadId: "streaming-visual", turnId: "stream-turn",
                streamKind: .assistant, delta: " plus exactly one delta."
            ))
            _ = projection.flushPendingStreamingMarkup()
            let touched = projection.drainTouchedNodes()
            let final = projection.document
            let finalViewDocument = AgentDocument(version: 2, entries: final.entries)
            let updated = Array(touched.ids).sorted { $0.rawValue < $1.rawValue }
            let patch = try AgentDocumentPatch(
                fromVersion: 1, toVersion: 2, updated: updated
            )
            try list.apply(document: finalViewDocument, patch: patch)
            list.layoutSubtreeIfNeeded(); list.collectionView.layoutSubtreeIfNeeded()
            let afterOffset = clip.bounds.minY
            let afterTailOffset = max(0, list.collectionView.bounds.height - clip.bounds.height)
            let afterDistanceToTail = afterTailOffset - afterOffset
            guard let afterAnchorFrame = list.collectionView.layoutAttributesForItem(at: selectionIndex)?.frame,
                  let afterStreamFrame = list.collectionView.layoutAttributesForItem(at: streamIndex)?.frame,
                  afterStreamFrame.intersects(clip.bounds), afterDistanceToTail > 2 else {
                throw fail("streaming pair lost anchor/stream/non-tail clip=\(clip.bounds) tail=\(afterTailOffset) distance=\(afterDistanceToTail) stream=\(String(describing: list.collectionView.layoutAttributesForItem(at: streamIndex)?.frame))")
            }
            let afterSelection = list.collectionView.selectionIndexPaths
            let afterAnchorY = afterAnchorFrame.minY - afterOffset
            let afterRep = try UIProbe.bitmap(of: probe.host, id: "streaming-delta-after")

            let finalIDs = final.entries.flatMap { [$0.id] + $0.blocks.map(\.id) }
            guard initialIDs == finalIDs, updated.count == 2,
                  beforeSelection == afterSelection,
                  list.qaDisclosureState(for: disclosureID) == true,
                  abs(afterAnchorY - beforeAnchorY) <= 2 else {
                throw fail("streaming delta pair violated invariants ids=\(initialIDs == finalIDs) updated=\(updated.map(\.rawValue)) selection=\(beforeSelection)->\(afterSelection) anchor=\(beforeAnchorY)->\(afterAnchorY)")
            }

            let tailList = AgentTranscriptListView(renderContext: AgentRenderContext(
                actions: .disabled, tokens: .transcript,
                appearance: appearance == .darkAqua ? .dark : .light
            ))
            tailList.frame = NSRect(origin: .zero, size: size)
            try tailList.apply(
                document: initialViewDocument,
                patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: initialBlockIDs)
            )
            tailList.layoutSubtreeIfNeeded(); tailList.collectionView.layoutSubtreeIfNeeded()
            let tailClip = tailList.scrollView.contentView
            tailList.jumpToLatest()
            try tailList.apply(document: finalViewDocument, patch: patch)
            tailList.layoutSubtreeIfNeeded(); tailList.collectionView.layoutSubtreeIfNeeded()
            let tailMaximum = max(0, tailList.collectionView.bounds.height - tailClip.bounds.height)
            guard abs(tailClip.bounds.minY - tailMaximum) <= 2 else {
                throw fail("streaming delta pair did not keep a tail-following viewport pinned")
            }

            let beforeName = "semantic-transcript-streaming-delta-before-480x720-\(shortName(appearance)).png"
            let afterName = "semantic-transcript-streaming-delta-after-480x720-\(shortName(appearance)).png"
            guard let beforePNG = beforeRep.representation(using: .png, properties: [:]),
                  let afterPNG = afterRep.representation(using: .png, properties: [:]) else {
                throw fail("streaming delta pair could not encode PNG")
            }
            let beforeBytes = beforeRep.bitmapData.map { Data(bytes: $0, count: beforeRep.bytesPerRow * beforeRep.pixelsHigh) } ?? Data()
            let afterBytes = afterRep.bitmapData.map { Data(bytes: $0, count: afterRep.bytesPerRow * afterRep.pixelsHigh) } ?? Data()
            let changedBytes = zip(beforeBytes, afterBytes).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            let changedFraction = beforeBytes.isEmpty ? 1 : Double(changedBytes) / Double(beforeBytes.count)
            guard changedBytes > 0, changedFraction < 0.20 else {
                throw fail("streaming delta pixel diff was empty or unbounded: \(changedBytes) bytes, \(changedFraction)")
            }
            try beforePNG.write(to: directory.appendingPathComponent(beforeName))
            try afterPNG.write(to: directory.appendingPathComponent(afterName))
            records.append(Record(surface: "semantic-transcript", state: "streaming-delta-before", size: size, appearance: appearance, fileName: beforeName, digest: UIProbe.digest(of: beforeRep)))
            records.append(Record(surface: "semantic-transcript", state: "streaming-delta-after", size: size, appearance: appearance, fileName: afterName, digest: UIProbe.digest(of: afterRep)))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            semanticPairs.append([
                "appearance": shortName(appearance), "delta_count": 1,
                "initial_document_sha256": sha256(try encoder.encode(initial)),
                "final_document_sha256": sha256(try encoder.encode(final)),
                "stable_node_ids": initialIDs.map(\.rawValue),
                "updated_node_ids": updated.map(\.rawValue),
                "initial_version": initial.version, "final_version": final.version,
                "projection_initial_version": initial.version, "projection_final_version": final.version,
                "patch": ["from": patch.fromVersion, "to": patch.toVersion, "updated": updated.map(\.rawValue)],
                "selection_unchanged": true,
                "selection_index_paths": beforeSelection.map { [$0.section, $0.item] },
                "disclosure_state": ["block_id": disclosureID.rawValue, "expanded_before_after": true],
                "non_tail_before_offset": beforeOffset, "non_tail_after_offset": afterOffset,
                "anchor_node_id": anchorNodeID.rawValue, "anchor_before_y": beforeAnchorY, "anchor_after_y": afterAnchorY,
                "anchor_delta": abs(afterAnchorY - beforeAnchorY), "tail_following_pinned": true,
                "non_tail_before_distance_to_tail": beforeDistanceToTail,
                "non_tail_after_distance_to_tail": afterDistanceToTail,
                "changed_pixel_bytes": changedBytes, "changed_pixel_fraction": changedFraction,
                "before_pixel_sha256": sha256(beforePNG), "after_pixel_sha256": sha256(afterPNG),
                "point_size": [480, 720], "pixel_size": [960, 1440], "scale": 2
            ])
        }
        let semantic: [String: Any] = [
            "schema_version": 1, "state_id": "streaming-delta-pair",
            "candidate_sha": ProcessInfo.processInfo.environment["CONTINUUM_CANDIDATE_SHA"] ?? "precommit",
            "production_path": "AgentTranscriptProjection.ingest -> drainTouchedNodes -> AgentDocumentPatch -> AgentTranscriptListView.apply",
            "pairs": semanticPairs, "candidate_only": true, "judgment": "NEEDS_JUDGMENT"
        ]
        let data = try JSONSerialization.data(withJSONObject: semantic, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("streaming-delta-pair.semantic.json"))
        return records
    }

    /// One row of the contact sheet.
    struct Record {
        let surface: String
        let state: String
        let size: NSSize
        let appearance: NSAppearance.Name
        let fileName: String
        let digest: String
    }

    /// `index.md` — the point of the whole check. Every image, with the
    /// parameters that produced it, plus a per-surface/state light-vs-dark
    /// "differ?" column computed from the render digests.
    ///
    /// That column is **reported, not asserted**: two identical appearance
    /// renders are a harness bug, and `--ui-probe-check` is what turns that red.
    /// Here it exists so a reviewer opening a pair does not have to eyeball
    /// whether the theme moved.
    static func indexMarkdown(records: [Record], directory: URL) -> String {
        var digestsByKey: [String: [String: String]] = [:]
        for record in records {
            digestsByKey["\(record.surface)/\(record.state)/\(Int(record.size.width))", default: [:]][shortName(record.appearance)] = record.digest
        }

        var lines: [String] = [
            "# UI tour",
            "",
            "Advisory contact sheet written by `--ui-tour-check`. **Nothing here gates the matrix** —",
            "it exists so every render says what it is: surface, state, size in points, and appearance.",
            "",
            "- Directory: `\(directory.path)`",
            "- Images: \(records.count)",
            "- Appearances: \(appearances.map { shortName($0) }.joined(separator: ", "))",
            "",
            "`aqua != darkAqua` compares the two appearance renders of the same surface/state/size by",
            "pixel digest. A `no` means the appearance did not reach the view — a harness bug, which",
            "`--ui-probe-check` gates; this column is reported only.",
            "",
            "| surface | state | size (pt) | appearance | aqua != darkAqua | image |",
            "|---|---|---|---|---|---|"
        ]
        for record in records {
            let pair = digestsByKey["\(record.surface)/\(record.state)/\(Int(record.size.width))"] ?? [:]
            let differs: String
            if let light = pair["aqua"], let dark = pair["darkAqua"] {
                differs = light == dark ? "no" : "yes"
            } else {
                differs = "n/a"
            }
            lines.append(
                "| \(record.surface) | \(record.state) | \(Int(record.size.width))x\(Int(record.size.height)) "
                    + "| \(shortName(record.appearance)) | \(differs) | `\(record.fileName)` |"
            )
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Check

    static func runTourCheck() throws {
        _ = NSApplication.shared
        // Production pins the app appearance at launch (`ContinuumApp`), so pin it
        // dark here too: an `.aqua` shot that forgot to set its own appearance
        // would come back dark and be caught, not silently mislabelled.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let directory = try tourDirectory()
        var records: [Record] = []

        for shot in try plan() {
            let probe = try UIProbe.render(
                UIProbe.Spec(id: shot.fileName, size: shot.size, appearance: shot.appearance, renderScale: shot.scale),
                make: shot.make
            )
            try writePNG(probe.hostRep, to: directory.appendingPathComponent(shot.fileName))
            records.append(Record(
                surface: shot.surface, state: shot.state, size: shot.size, appearance: shot.appearance,
                fileName: shot.fileName, digest: probe.hostDigest
            ))
        }

        for appearance in appearances {
            let (rep, size) = try renderSettings(appearance: appearance)
            let fileName = "settings-all-sections-\(Int(size.width))x\(Int(size.height))-\(shortName(appearance)).png"
            try writePNG(rep, to: directory.appendingPathComponent(fileName))
            records.append(Record(
                surface: "settings", state: "all-sections", size: size, appearance: appearance,
                fileName: fileName, digest: UIProbe.digest(of: rep)
            ))
        }

        records.append(contentsOf: try writeStreamingDeltaPair(to: directory))

        let indexURL = directory.appendingPathComponent("index.md")
        try indexMarkdown(records: records, directory: directory).write(to: indexURL, atomically: true, encoding: .utf8)

        // Mechanical, not visual: the tour has to have actually written what it
        // says it wrote, or the sheet is a lie. Nothing below judges a render.
        let onDisk = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasSuffix(".png") } ?? []
        )
        let expected = Set(records.map(\.fileName))
        guard onDisk == expected else {
            throw fail(
                "tour wrote \(onDisk.count) PNG(s) but indexed \(expected.count) in \(directory.path) — "
                    + "missing: \(expected.subtracting(onDisk).sorted().joined(separator: ", "))"
            )
        }

        guard NSApp.appearance?.name == .darkAqua else {
            throw fail("the tour mutated NSApp.appearance to '\(NSApp.appearance?.name.rawValue ?? "nil")'")
        }

        let identicalPairs = Dictionary(grouping: records) { "\($0.surface)/\($0.state)/\(Int($0.size.width))" }
            .filter { $0.value.count == 2 && $0.value[0].digest == $0.value[1].digest }
            .keys.sorted()
        print(
            "UITourCheck: wrote \(records.count) labelled render(s) + index.md to \(directory.path) "
                + "(\(appearances.count) appearances; ADVISORY — this check gates nothing visual)"
        )
        if !identicalPairs.isEmpty {
            // Reported on stdout, not thrown: see `indexMarkdown`.
            print("UITourCheck: NOTE — appearance pairs with identical pixels (see --ui-probe-check): \(identicalPairs.joined(separator: ", "))")
        }
    }

    // MARK: - Witnesses
    //
    // Both were applied, run, and observed; the quoted text is the real output.
    //
    // 1 · The non-gating property, which is the whole design constraint. With
    //     `TranscriptCardViews.swift` changed to `bodyLabel.textColor =
    //     Self.background(for: card.kind)` — every card body invisible, the exact
    //     class of bug this program exists to catch:
    //       --ui-tour-check  -> exit 0, "ContinuumRevivedUITourChecks passed"
    //       --ui-pixel-check -> exit 1, "managedAgent.NSAppearanceNameAqua
    //                           NSTextField: text rect is flat — luminance spread
    //                           0.000 over 23424 px, needs >= 0.050"
    //     The deterministic gate catches it; the tour stays green and simply
    //     *shows* it — `transcript-cards-all-kinds-520x560-darkAqua.png` renders
    //     six card headers over six empty bodies. That is the division of labour
    //     the packet asks for.
    //
    // 2 · Mechanical breakage is reported, loudly, but still does not gate. With
    //     `labSurfaces`' id changed to a card that does not exist, the flag alone
    //     exits 1:
    //       -> "FAIL: missing static Component Lab card 'chrome.sidebar.vanished'
    //           for tour surface 'sidebar'"
    //     and the full matrix around it stays green, by design:
    //       -> "run-matrix: WARNING — the advisory UI tour exited 1 (see above).
    //           It does NOT gate the matrix …"
    //       -> "Matrix passed.", `./scripts/run-matrix.sh` exit 0
    //     A sheet that silently stopped covering a surface would be worse than no
    //     sheet, which is why the failure is printed rather than swallowed.
}
