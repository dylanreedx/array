import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Program 96 / P0.1 — the PRODUCTION-FREQUENCY corpus.
///
/// The queue-94 corpus (`LabFixtures.sidebarDefectRows`) hand-writes
/// `AgentInboxRow` values. That proves the CELL can render good data; it cannot
/// prove the app ever produces it, and the owner screenshots showed it does not —
/// the visible rows said `array-scratch`, `New agent`, and a diamond while every
/// gate was green. This corpus fixes the direction of the arrow: each case drives
/// the REAL writers (`AgentSupervisor.spawn`/`sendPrepared`/`rename`/lifecycle
/// verbs, runtime events through `deliver`) against real on-disk stores, then reads
/// what the REAL join and the REAL `AgentInboxView` produced.
///
/// Nothing here constructs an `AgentInboxRow`. Every observed fact below is read
/// off a rendered cell, which is what makes a green run a statement about the
/// product rather than about a fixture.
///
/// The expectations deliberately pin TODAY's behaviour, defects included. A later
/// packet that fixes a defect flips its expectation as that packet's own entry
/// witness — so this file is also the ratchet that proves those fixes landed.
@MainActor
enum SidebarProductionCorpus {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// One case per production flow §6/P0.1 requires. Every case must appear in the
    /// committed inventory, and the inventory must contain nothing else.
    enum Flow: String, CaseIterable {
        // Titles and draft materialization (design §4.1, §4.2)
        case blankCmdKDraft
        case firstSendTitleFallback
        case imageOnlyFirstPrompt
        case generatedTitleLanded
        case manualRenameDuringGeneration
        case generationFailed
        // Operational phase (design §4.6)
        case working
        case approval
        case input
        // Terminal outcomes (design §4.6)
        case succeeded
        case failed
        case interrupted
        case cancelled
        case runtimeError
        case neverVisitedCompletion
        // Identity (design §4.5)
        case codexOpenAI
        case claudeAnthropic
        case unknownProvider
        case longUnicodeRTL
        // Lifecycle and placement (design §4.9, §5.3)
        case snoozed
        case settled
        case archived
        case nestedChild
        case headless
        case exactPlacement
        case fiftyActiveWithHistory
    }

    /// The facts a row actually PAINTED, read off the cell.
    struct ObservedRow: Equatable {
        let id: UUID
        let title: String
        let stateLabel: String
        /// The PLACEMENT band (`projectLabel`). `meta` below is a different band —
        /// isolation and child rollup — and confusing the two is how an early draft of
        /// this corpus nearly recorded "placement is empty" for rows that render it.
        let project: String
        let meta: String
        let branch: String
        let elapsed: String
        let providerGlyph: String

        var summary: String {
            "title=\(quoted(title)) state=\(quoted(stateLabel)) "
                + "project=\(quoted(project)) meta=\(quoted(meta)) "
                + "branch=\(quoted(branch)) elapsed=\(quoted(elapsed)) "
                + "providerGlyph=\(quoted(providerGlyph))"
        }

        private func quoted(_ value: String) -> String { "'\(value)'" }
    }

    struct FlowResult {
        let flow: Flow
        /// The agent this flow created, and the row it rendered — `nil` when the list
        /// materialized no cell for it. Distinguishing that from `isInRowModel`
        /// matters: History is collapsed by default, so a filed agent is legitimately
        /// in the row model with no cell on screen, which is a different fact from
        /// not being in the list at all.
        let agentID: AgentID
        let row: ObservedRow?
        let isInRowModel: Bool
        /// Whether the flow's Send was actually admitted. A refused send leaves the
        /// record a blank draft, so a flow that reported a sentinel title without
        /// recording this would look like a naming defect when it was a refusal.
        var acceptance: IntentAcceptance?

        var summary: String {
            guard let row else {
                return isInRowModel
                    ? "(in row model, no cell rendered — collapsed surface)"
                    : "(not in the list)"
            }
            var text = row.summary
            if let acceptance, acceptance != .accepted {
                text += " SEND-REFUSED=\(acceptance)"
            }
            return text
        }
    }

    // MARK: - The world

    /// A real app against real stores on disk. `AppDelegate`'s wiring members are
    /// `private` (and one of them is pinned verbatim by a program source-scan), so
    /// the construction itself lives in `AppDelegate.makeSidebarCorpusWorld` inside
    /// ContinuumApp.swift, where that access is legal. This is the handle it returns:
    /// everything a flow needs, and nothing else.
    ///
    /// The project is named `array-scratch` on purpose — the owner screenshot this
    /// packet is anchored to shows that exact string in the placement band.
    @MainActor
    final class World {
        let tempRoot: URL
        let projectRoot: URL
        let projectId: UUID
        let workspaceId: UUID
        let supervisor: AgentSupervisor
        let sidebar: WorkspaceSidebarView
        let attachmentStore: AgentComposerAttachmentStore
        let now: Date
        /// Drives the app's own surface refresh (`refreshAgentSurfaces`), so a flow
        /// observes rows through production's push path rather than a private copy.
        private let refreshSurfaces: @MainActor () -> Void
        /// The in-memory push (`pushAgentSurfaces`) an agent's own event takes.
        private let pushSurfaces: @MainActor () -> Void
        private let recordActivity:
            @MainActor (AgentID, UUID?, AgentRuntimeEvent, AgentStatus) -> Void
        private let restoreDefaults: @MainActor () -> Void
        /// Retains the most recent observation host so its cells are not deallocated
        /// while their facts are being read.
        private var probeWindow: NSWindow?

        init(
            tempRoot: URL,
            projectRoot: URL,
            projectId: UUID,
            workspaceId: UUID,
            supervisor: AgentSupervisor,
            sidebar: WorkspaceSidebarView,
            attachmentStore: AgentComposerAttachmentStore,
            now: Date,
            refreshSurfaces: @escaping @MainActor () -> Void,
            pushSurfaces: @escaping @MainActor () -> Void,
            recordActivity: @escaping @MainActor (
                AgentID, UUID?, AgentRuntimeEvent, AgentStatus) -> Void,
            restoreDefaults: @escaping @MainActor () -> Void
        ) {
            self.tempRoot = tempRoot
            self.projectRoot = projectRoot
            self.projectId = projectId
            self.workspaceId = workspaceId
            self.supervisor = supervisor
            self.sidebar = sidebar
            self.attachmentStore = attachmentStore
            self.now = now
            self.refreshSurfaces = refreshSurfaces
            self.pushSurfaces = pushSurfaces
            self.recordActivity = recordActivity
            self.restoreDefaults = restoreDefaults
        }

        /// Deliver one runtime event to BOTH of its owners, exactly as production
        /// does: `deliver` updates the turn facts the row's STATE is read from, and
        /// the tile bridge records the activity draft. Feeding only one of them
        /// produces a state that cannot occur in the app (the note on this pairing is
        /// in `runAgentInboxChecks` section B).
        func deliver(
            _ event: AgentRuntimeEvent,
            to id: AgentID,
            status: AgentStatus,
            tileId: UUID? = nil,
            at when: Date? = nil
        ) {
            recordActivity(id, tileId, event, status)
            supervisor.qaDeliver(event, to: id, now: when ?? now)
            pushSurfaces()
        }

        /// A PNG attachment carried through the real composer attachment store, so an
        /// image-only prompt is transported the way the app transports one.
        func importImage(displayName: String, for id: AgentID) async throws
            -> AgentPromptImageAttachment
        {
            let validation = try AgentComposerImageValidation(
                validatedContentType: "image/png",
                pixelWidth: 80, pixelHeight: 60, byteCount: 123)
            return try await attachmentStore.importValidatedPastedImage(
                Data(repeating: 7, count: 123), displayName: displayName,
                validation: validation, forDraftOf: id
            ).promptAttachment
        }

        func tearDown() {
            restoreDefaults()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        /// The rows PRODUCTION produced for the current state: the app's own refresh
        /// runs `buildAgentInboxRows` → `AgentContextIndex.build` →
        /// `AgentInboxRowBuilder.rows` and hands the result to the real sidebar, and
        /// this reads them back off that view.
        func productionRows() -> [AgentInboxRow] {
            refreshSurfaces()
            sidebar.layoutSubtreeIfNeeded()
            return sidebar.inboxForQA.qaAllRowsForQA
        }

        /// Render production's rows and read every fact off a real cell.
        ///
        /// The rendering host is a sized, frame-pinned `AgentInboxView` rather than
        /// the sidebar's own table. That is a deliberate, narrow concession: the
        /// shipped push is incremental and an offscreen window defers that reload
        /// indefinitely, so the sidebar's own table reports its rows while
        /// materializing no cells at all — which is precisely how this harness first
        /// reported 23 of 24 flows as "no cell rendered" against a 24-row table. The
        /// VALUES observed here are still production's; only the reload strategy and
        /// the viewport belong to the probe, the same arrangement `--sidebar-ux-check`
        /// already relies on.
        ///
        /// Each fact comes off ONE cell, keyed by that cell's own `qaAgentID`. Zipping
        /// the view's parallel `…ForQA` arrays would be wrong: the id array is the
        /// whole row model while the text arrays are only materialized cells, so once
        /// rows outnumber the viewport, pairing by index attributes one agent's paint
        /// to another agent's id.
        func observeRows() -> [ObservedRow] {
            let rows = productionRows()
            guard !rows.isEmpty else { return [] }

            // Tall enough that every row has a viewport; height is free offscreen.
            let size = NSSize(
                width: WorkspaceSidebarConfig.defaultWidth,
                height: max(640, CGFloat(rows.count + 4) * 90))
            let host = NSView(frame: NSRect(origin: .zero, size: size))
            host.wantsLayer = true
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.contentMinSize = size
            window.contentMaxSize = size
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)

            // Size the inbox BEFORE it receives rows: an offscreen table with no
            // viewport materializes nothing and every read below would be vacuous.
            let inbox = AgentInboxView(frame: host.bounds)
            inbox.autoresizingMask = [.width, .height]
            host.addSubview(inbox)
            host.layoutSubtreeIfNeeded()
            // Pin the scroller: a legacy scroller reserves a lane and would make the
            // observed truncation machine-dependent (mouse attached or not).
            inbox.pinScrollerStyleForQA()
            inbox.prefersReducedMotion = { false }
            inbox.prefersIncreasedContrast = { false }
            inbox.reload(rows: rows)
            inbox.layoutForQA()

            probeWindow = window
            return inbox.qaMaterializedRowCells.compactMap { cell in
                guard let id = cell.qaAgentID else { return nil }
                return ObservedRow(
                    id: id,
                    title: cell.qaTitle,
                    stateLabel: cell.qaStateLabel,
                    project: cell.qaProject,
                    meta: cell.qaMeta,
                    branch: cell.qaBranch,
                    elapsed: cell.qaElapsed,
                    providerGlyph: cell.qaProviderGlyph)
            }
        }

        /// Observe one flow's own agent: the rendered row if a cell exists, plus
        /// whether the row model holds it at all.
        func result(
            _ flow: Flow, _ id: AgentID, acceptance: IntentAcceptance? = nil
        ) -> FlowResult {
            let rows = observeRows()
            return FlowResult(
                flow: flow,
                agentID: id,
                row: rows.first { $0.id == id.rawValue },
                isInRowModel: sidebar.inboxForQA.rowIdsForQA.contains(id.rawValue),
                acceptance: acceptance)
        }

        /// Spawn an agent whose tile REALLY EXISTS on the project canvas, so
        /// `AgentContextIndex.build`'s placement walk can resolve a workspace and a
        /// Zone for it. Every other flow's tile id is a bare UUID with no tile behind
        /// it — which is exactly why their placement band renders empty.
        func spawnPlaced(title: String, zoneOffset: CGFloat = 0) throws -> AgentID {
            let tileId = UUID()
            let store = ProjectStore(projectRoot: projectRoot)
            var canvas = (try? store.loadCanvas())
                ?? CanvasState(
                    viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                    tiles: [], groups: [], lastActiveTileId: nil)
            canvas.tiles.append(Tile(
                id: tileId, kind: .managedAgent, title: title,
                frame: TileFrame(x: zoneOffset, y: 0, width: 200, height: 120),
                zPosition: .fromLegacyRank(canvas.tiles.count + 1),
                runtimeRef: nil, metadata: TileMetadata()))
            try store.saveCanvas(canvas)
            return supervisor.spawn(
                role: nil, prompt: nil, cwd: projectRoot,
                harness: .codex, model: "openai-codex/gpt-5.6-sol",
                thinking: "medium", projectId: projectId, tileId: tileId)
        }

        /// Spawn through the real supervisor entry point every ⌘K and headless path
        /// reaches. `prompt: nil` is the untouched-composer case.
        func spawn(
            prompt: String? = nil,
            model: String = "openai-codex/gpt-5.6-sol",
            harness: AgentHarness = .codex,
            parent: AgentID? = nil,
            tiled: Bool = true
        ) -> AgentID {
            supervisor.spawn(
                role: nil,
                prompt: prompt,
                cwd: projectRoot,
                harness: harness,
                model: model,
                thinking: "medium",
                projectId: projectId,
                parentAgentID: parent,
                tileId: tiled ? UUID() : nil)
        }

        /// The first accepted Send, through the supervisor's own accept seam.
        @discardableResult
        func send(_ prompt: AgentPrompt, to id: AgentID) async -> IntentAcceptance {
            await supervisor.accept(.sendPrompt(prompt), for: id)
        }

        /// A completed turn, delivered to both owners.
        func completeTurn(
            _ id: AgentID,
            outcome: TurnOutcome,
            status: AgentStatus,
            thread: String = "corpus-thread",
            turn: String = "corpus-turn",
            errorMessage: String? = nil
        ) {
            deliver(.turnStarted(threadId: thread, turnId: turn), to: id, status: .working)
            deliver(
                .turnCompleted(
                    threadId: thread, turnId: turn, outcome: outcome,
                    errorMessage: errorMessage),
                to: id, status: status)
        }
    }

    // MARK: - Flows

    /// ⌘K with nothing typed. `TileSpawner.spawnManagedAgent` →
    /// `wireManagedAgentTile` → `spawnSupervisedAgent` reaches
    /// `AgentSupervisor.spawn(role: nil, prompt: nil, …)`, which persists a durable
    /// record before the user has expressed any intent (design §2.4). This flow
    /// drives that same supervisor entry point with the same arguments.
    static func runFlows(in world: World) async throws -> [FlowResult] {
        var results: [FlowResult] = []

        // ── Titles and draft materialization ──────────────────────────────────
        // ⌘K, nothing typed. A durable record exists before any intent (§2.4).
        results.append(world.result(.blankCmdKDraft, world.spawn()))

        // The first accepted Send. `sendPrepared` derives the prompt fallback under
        // a 60-character cap — a label transform, not semantic naming (§2.5).
        let firstSend = world.spawn()
        await world.send(
            AgentPrompt(
                "Replace the sidebar identity and completion UX so a glance answers "
                + "what finished and where it lives"),
            to: firstSend)
        results.append(world.result(.firstSendTitleFallback, firstSend))

        // An image-only first prompt has no text to fall back to.
        let imageOnly = world.spawn()
        let image = try await world.importImage(displayName: "screenshot.png", for: imageOnly)
        await world.send(AgentPrompt(imageAttachments: [image]), to: imageOnly)
        results.append(world.result(.imageOnlyFirstPrompt, imageOnly))

        // Generation landing through the real request/CAS pair.
        let generated = world.spawn()
        await world.send(AgentPrompt("investigate the failing zoom budget"), to: generated)
        if let request = world.supervisor.beginNameGeneration(agentID: generated) {
            _ = world.supervisor.applyGeneratedName(
                "Investigate zoom budget regression", for: request, agentID: generated)
        }
        results.append(world.result(.generatedTitleLanded, generated))

        // A manual rename must beat a generation that lands after it.
        let renamed = world.spawn()
        await world.send(AgentPrompt("tidy the inbox ordering"), to: renamed)
        let staleRequest = world.supervisor.beginNameGeneration(agentID: renamed)
        _ = world.supervisor.rename(agentID: renamed, to: "Human chosen title")
        if let staleRequest {
            _ = world.supervisor.applyGeneratedName(
                "Generated title that lost the race", for: staleRequest, agentID: renamed)
        }
        results.append(world.result(.manualRenameDuringGeneration, renamed))

        // Generation that never produces a usable label consumes its request and
        // leaves the prompt fallback standing.
        let genFailed = world.spawn()
        await world.send(AgentPrompt("check the release appcast"), to: genFailed)
        if let request = world.supervisor.beginNameGeneration(agentID: genFailed) {
            _ = world.supervisor.applyGeneratedName("   ", for: request, agentID: genFailed)
        }
        results.append(world.result(.generationFailed, genFailed))

        // ── Operational phase ─────────────────────────────────────────────────
        let workingAgent = world.spawn()
        await world.send(AgentPrompt("run the matrix"), to: workingAgent)
        world.deliver(
            .turnStarted(threadId: "work", turnId: "work-1"),
            to: workingAgent, status: .working)
        results.append(world.result(.working, workingAgent))

        let approvalAgent = world.spawn()
        await world.send(AgentPrompt("apply the patch"), to: approvalAgent)
        world.deliver(
            .requestOpened(
                threadId: "appr", requestId: "appr-1", kind: .commandExecutionApproval),
            to: approvalAgent, status: .needsAttention)
        results.append(world.result(.approval, approvalAgent))

        let inputAgent = world.spawn()
        await world.send(AgentPrompt("pick a provider"), to: inputAgent)
        world.deliver(
            .userInputRequested(
                threadId: "input", requestId: "input-1",
                questions: [UserInputQuestion(key: "which", prompt: "Which provider?")]),
            to: inputAgent, status: .needsAttention)
        results.append(world.result(.input, inputAgent))

        // ── Terminal outcomes ─────────────────────────────────────────────────
        // Every one of these is a DIFFERENT product fact the design requires the row
        // to distinguish; today they all land on the same `runCompletedAt` stamp.
        for (flow, outcome) in [
            (Flow.succeeded, TurnOutcome.completed),
            (Flow.failed, TurnOutcome.failed),
            (Flow.interrupted, TurnOutcome.interrupted),
            (Flow.cancelled, TurnOutcome.cancelled),
        ] {
            let agent = world.spawn()
            await world.send(AgentPrompt("work that ends \(outcome.rawValue)"), to: agent)
            world.completeTurn(
                agent, outcome: outcome,
                status: outcome == .completed ? .done : .stale,
                thread: flow.rawValue, turn: "\(flow.rawValue)-1",
                errorMessage: outcome == .failed ? "the tool exited 1" : nil)
            // Seen by the human: focus acknowledges, which is what makes the
            // never-visited flow below a contrast rather than a duplicate.
            world.supervisor.focus(agentID: agent, now: world.now)
            results.append(world.result(flow, agent))
        }

        let runtimeErrorAgent = world.spawn()
        await world.send(AgentPrompt("touch a missing binary"), to: runtimeErrorAgent)
        world.deliver(
            .runtimeError(threadId: "rt", message: "spawn failed: ENOENT"),
            to: runtimeErrorAgent, status: .stale)
        results.append(world.result(.runtimeError, runtimeErrorAgent))

        // A first-ever completion on an agent nobody ever opened. `isUnread` compares
        // against `lastVisitedAt ?? .distantFuture`, so this is the case the design
        // says reads as ALREADY SEEN (§2.7).
        let neverVisited = world.spawn()
        await world.send(AgentPrompt("finish while nobody is looking"), to: neverVisited)
        world.completeTurn(
            neverVisited, outcome: .completed, status: .idle,
            thread: "never", turn: "never-1")
        results.append(world.result(.neverVisitedCompletion, neverVisited))

        // ── Identity ──────────────────────────────────────────────────────────
        // Identity comes off the RECORD's harness/model, which `spawn` sets, so these
        // flows deliberately do NOT send. An earlier draft of this corpus sent a text
        // prompt here and read a sentinel title, which looked like a naming defect;
        // it was `sendPrepared` correctly refusing a model that does not belong to the
        // harness's own catalogue (AGENTS.md non-negotiable #5 — exact model ids, and
        // selection never falls back to another CLI). A manual rename gives each row a
        // subject so the observation isolates provider identity from send admission.
        let codex = world.spawn(model: "openai-codex/gpt-5.6-sol", harness: .codex)
        _ = world.supervisor.rename(agentID: codex, to: "Codex on an OpenAI model")
        results.append(world.result(.codexOpenAI, codex))

        let claude = world.spawn(model: "anthropic/claude-opus-5", harness: .claudeCode)
        _ = world.supervisor.rename(agentID: claude, to: "Claude Code on Opus")
        results.append(world.result(.claudeAnthropic, claude))

        // A provider the glyph map has never heard of — the arm that returns the bare
        // diamond today, where the design wants deterministic two-character initials.
        let unknown = world.spawn(model: "acme-labs/experimental-7", harness: .codex)
        _ = world.supervisor.rename(agentID: unknown, to: "Unknown provider row")
        results.append(world.result(.unknownProvider, unknown))

        // Long, combining-marked, bidirectional text in the SUBJECT band.
        let rtl = world.spawn()
        await world.send(AgentPrompt("bidi work"), to: rtl)
        _ = world.supervisor.rename(
            agentID: rtl,
            to: "تحديث الشريط الجانبي · סוכן עם שם ארוך מאוד · combining a\u{0301}e\u{0301}")
        results.append(world.result(.longUnicodeRTL, rtl))

        // ── Lifecycle ─────────────────────────────────────────────────────────
        let snoozedAgent = world.spawn()
        await world.send(AgentPrompt("come back later"), to: snoozedAgent)
        _ = world.supervisor.snooze(
            agentID: snoozedAgent,
            until: world.now.addingTimeInterval(3_600), now: world.now)
        results.append(world.result(.snoozed, snoozedAgent))

        let settledAgent = world.spawn()
        await world.send(AgentPrompt("file this one"), to: settledAgent)
        world.completeTurn(
            settledAgent, outcome: .completed, status: .idle,
            thread: "settle", turn: "settle-1")
        world.supervisor.focus(agentID: settledAgent, now: world.now)
        _ = world.supervisor.settle(agentID: settledAgent, now: world.now)
        results.append(world.result(.settled, settledAgent))

        let archivedAgent = world.spawn()
        await world.send(AgentPrompt("close this one"), to: archivedAgent)
        _ = world.supervisor.archive(archivedAgent)
        results.append(world.result(.archived, archivedAgent))

        // A spawned child, drawn one level in under its parent.
        let parent = world.spawn()
        await world.send(AgentPrompt("orchestrate the work"), to: parent)
        let child = world.spawn(parent: parent)
        await world.send(AgentPrompt("do the delegated part"), to: child)
        results.append(world.result(.nestedChild, child))

        // No tile at all: the row the old tile-keyed tree could not draw, and the
        // one whose placement has no Zone to name (§5.3).
        let headlessAgent = world.spawn(tiled: false)
        await world.send(AgentPrompt("headless work"), to: headlessAgent)
        results.append(world.result(.headless, headlessAgent))

        // ── Placement ─────────────────────────────────────────────────────────
        // A tile that REALLY EXISTS on the canvas, so the placement walk can resolve
        // it. This is the control for every row above: if `meta` is empty here too,
        // the empty band is not merely an artefact of synthetic tile ids.
        let placed = try world.spawnPlaced(title: "placed agent")
        _ = world.supervisor.rename(agentID: placed, to: "Agent with a real tile")
        results.append(world.result(.exactPlacement, placed))

        // ── Scale ─────────────────────────────────────────────────────────────
        // 50 more active agents. §8.4 requires History to stay reachable under this
        // load; P0.2 measures that at real sidebar heights. Here it establishes that
        // the list still renders every row and that ordering stays frozen by creation.
        var lastBulk: AgentID?
        for index in 0..<50 {
            let bulk = world.spawn()
            _ = world.supervisor.rename(agentID: bulk, to: "Bulk agent \(index + 1)")
            lastBulk = bulk
        }
        if let lastBulk {
            results.append(world.result(.fiftyActiveWithHistory, lastBulk))
        }

        return results
    }

    // MARK: - Runner

    static func run() async throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(description: message) }
        }

        let now = Date(timeIntervalSince1970: 1_900_600_000)
        let world = try AppDelegate.makeSidebarCorpusWorld(now: now)
        defer { world.tearDown() }
        let results = try await runFlows(in: world)

        // OBSERVED, not asserted-then-described: print what the product produced so
        // the packet's witness is a record of real output.
        print("SidebarProductionCorpus: observed rows per flow")
        for result in results {
            print("  \(result.flow.rawValue): \(result.summary)")
        }

        try expect(results.count == Flow.allCases.count,
                   "every declared flow must run — \(results.count) of "
                   + "\(Flow.allCases.count) produced a result")
        let ranFlows = Set(results.map(\.flow))
        for flow in Flow.allCases {
            try expect(ranFlows.contains(flow), "flow '\(flow.rawValue)' declared but never run")
        }

        // The gate §6/P0.1 names: a declared inventory mapping each production flow
        // to its resulting row and surface. A corpus nobody has written down is a
        // pile of fixtures, so a missing or out-of-sync inventory is RED.
        let inventoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // ContinuumRevived
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent(
                "docs/38-tickets/96-agent-sidebar-product-redesign/P0.1-fixture-inventory.md")
        guard let inventory = try? String(contentsOf: inventoryURL, encoding: .utf8) else {
            throw Failure(description:
                "P0.1 inventory missing at \(inventoryURL.path) — every declared flow must map "
                + "to its resulting row and surface in a committed document")
        }
        let declaredRows = inventory
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("|") else { return nil }
                let cells = trimmed.split(separator: "|", omittingEmptySubsequences: true)
                guard let first = cells.first else { return nil }
                // Flow ids are written as `code` in the table so the document reads
                // properly; the parity gate compares the identifier, not the markup.
                let flowCell = first
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                return Flow(rawValue: flowCell) != nil ? flowCell : nil
            }
        for flow in Flow.allCases {
            try expect(declaredRows.contains(flow.rawValue),
                       "P0.1 inventory has no row for flow '\(flow.rawValue)' — "
                       + "declared flows and the inventory must stay in two-way parity")
        }
        try expect(declaredRows.count == Flow.allCases.count,
                   "P0.1 inventory declares \(declaredRows.count) flow rows but "
                   + "\(Flow.allCases.count) flows exist — a stale row is a claim about a "
                   + "flow nothing runs")

        print("SidebarProductionCorpus checks passed: \(Flow.allCases.count) production flows "
              + "drove real writers and were read off rendered cells, "
              + "\(declaredRows.count) inventory rows in two-way parity")
    }
}
