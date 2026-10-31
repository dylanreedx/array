import AppKit
import Foundation
import ObjectiveC
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Counts layout passes and view insertions inside watched view trees, by
/// class. It hooks `NSView.layout` and `NSView.didAddSubview(_:)` themselves,
/// so a collaboration view written later is counted without registering.
@MainActor
enum CollaborationWorkCensus {
    private static var installed = false
    private static var roots: [NSView] = []
    private(set) static var layouts: [String: Int] = [:]
    private(set) static var insertions: [String: Int] = [:]

    static func watch(_ views: [NSView]) {
        if !installed {
            installed = true
            swap(#selector(NSView.layout), #selector(NSView.collaborationCensus_layout))
            swap(#selector(NSView.didAddSubview(_:)), #selector(NSView.collaborationCensus_didAddSubview(_:)))
        }
        roots = views; layouts = [:]; insertions = [:]
    }
    static func stop() { roots = []; layouts = [:]; insertions = [:] }
    static var layoutTotal: Int { layouts.values.reduce(0, +) }
    /// Views inserted by Array code. AppKit's private views (a leading
    /// underscore, e.g. TextKit 2's `_NSTextViewportElementView` line fragments
    /// inside a text view whose text changed) are counted separately.
    static var insertionTotal: Int { insertions.filter { !$0.key.hasPrefix("_") }.values.reduce(0, +) }
    static var appKitInsertionTotal: Int { insertions.filter { $0.key.hasPrefix("_") }.values.reduce(0, +) }

    fileprivate static func noteLayout(_ view: NSView) {
        guard roots.contains(where: { view.isDescendant(of: $0) }) else { return }
        layouts[String(describing: type(of: view)), default: 0] += 1
    }
    fileprivate static func noteInsertion(_ subview: NSView, into parent: NSView) {
        guard roots.contains(where: { parent.isDescendant(of: $0) }) else { return }
        insertions[String(describing: type(of: subview)), default: 0] += 1
    }
    private static func swap(_ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(NSView.self, original), let b = class_getInstanceMethod(NSView.self, replacement) else { return }
        method_exchangeImplementations(a, b)
    }
}

extension NSView {
    @objc fileprivate func collaborationCensus_layout() {
        CollaborationWorkCensus.noteLayout(self)
        collaborationCensus_layout()
    }
    @objc fileprivate func collaborationCensus_didAddSubview(_ subview: NSView) {
        CollaborationWorkCensus.noteInsertion(subview, into: self)
        collaborationCensus_didAddSubview(subview)
    }
}

/// COL-21 budgets on the production mount: presence floods, follow, agreement
/// edits and remote operations must do zero transcript measurement, zero
/// canvas or store saves beyond the shared cache, zero model/executor work, and
/// bounded layout and view creation per event — counted, never timed.
@MainActor
enum CollaborationBudgetChecks {
    private typealias Rig = SharedAreaCheckRig
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Rig.Failure(description: message) }
        print("PASS collaboration budget: \(message)")
    }
    /// Per-event ceiling on layout passes in the whole shared window. Measured
    /// at 4.5 for agreement revisions (the reader, two labels and Endorse, all
    /// of which really change) after unchanged menus and labels stopped being
    /// reassigned; it was 10.4 before. A view tree rebuilt per event exceeds it.
    static let layoutPassesPerEvent = 6

    private struct Transcript: Equatable {
        let layouts: Int, code: Int, band: Int, markdown: Int, tables: Int
        @MainActor static func now() -> Transcript {
            .init(layouts: AgentTranscriptListView.qaTotalLayoutPasses, code: CodeTextView.qaUnwrappedMeasurementCount,
                  band: BandTextWidth.qaMeasurements, markdown: FileMarkdownDocumentView.qaTotalMeasurePasses,
                  tables: AgentTableView.qaNaturalWidthSolves)
        }
    }

    static func run(delegate: AppDelegate) async throws {
        let root = try Rig.root("budgets")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Collaboration.Identity(person: .init(), device: UUID()), b = Collaboration.Identity(person: .init(), device: UUID())
        let c = Collaboration.Identity(person: .init(), device: UUID())
        let discussion = SharedArea.Item(id: .init(), kind: .discussion), agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let placement = SharedArea.Position(id: .init(), object: discussion.id, rect: .init(x: 40, y: 40, width: 260, height: 180), z: 1)
        let first = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: a.person, text: "Revision 1")
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(discussion, placement),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 340, y: 40, width: 300, height: 200), z: 2)),
            .context(first)]))
        let authority = Rig.Authority(document: document, members: [(a, .owner), (b, .editor), (c, .editor)])
        var constructions = 0
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("supervisor")),
            makeRunner: { _ in constructions += 1; return ScriptedAgentRunner(script: []) })
        let previousSupervisor = delegate.agentSupervisor
        delegate.agentSupervisor = supervisor
        defer { delegate.agentSupervisor = previousSupervisor }
        let executors: () -> Int = { supervisor.records.keys.filter { supervisor.isRunning($0) }.count + constructions }

        let modelA = try Rig.controller(root: root.appendingPathComponent("a"), identity: a, label: "Peer A", authority: authority)
        let modelB = try Rig.controller(root: root.appendingPathComponent("b"), identity: b, label: "Peer B", authority: authority)
        let hostA = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 760))
        let sceneA = delegate.mountWorkspaceSceneAtBoot(sharedAreaController: modelA, person: a.person, in: hostA)
        hostA.layoutSubtreeIfNeeded()
        let publisherA = SharedAreaPresencePublisher(scene: sceneA)
        let windowB = SharedAreaWindowController(controller: modelB, person: b.person, delegate: delegate)
        let sceneB = windowB.scene, publisherB = windowB.presencePublisher, overlay = publisherB.overlay
        sceneA.reduceMotion = { true }; sceneB.reduceMotion = { true }
        windowB.show(); await windowB.waitUntilOpen(); await modelA.open()
        publisherA.start()
        defer { publisherA.stop(); sceneA.unmount(); windowB.window.close() }
        try sceneB.selectObject(agreement.id)
        let window = windowB.window
        func settle() { window.layoutIfNeeded(); window.displayIfNeeded() }
        /// Layer-backed views paint at the next commit, so a baseline is taken
        /// only once paint counts have stopped moving for a few turns.
        func quiesce() async throws {
            var stable = 0, last = (sceneB.contentDrawCount, overlay.drawCount)
            for _ in 0..<200 where stable < 3 {
                settle(); try await Task.sleep(for: .milliseconds(10))
                let now = (sceneB.contentDrawCount, overlay.drawCount)
                stable = now == last ? stable + 1 : 0; last = now
            }
        }
        settle()
        try expect(!sceneB.agreementPanel.isHidden, "the measured client shows a shared scene with its agreement panel")

        let source = root.appendingPathComponent("source/.array/canvas.json")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceBytes = Data("personal canvas".utf8); try sourceBytes.write(to: source)
        let sharedCache = modelB.localAreaDirectory.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path, aPath = root.appendingPathComponent("a").standardizedFileURL.path
        // Every store mutation under the rig except client A's own navigation.
        StoreFileWriter.install(.init(fault: .none, scope: root, matching: { !$0.standardizedFileURL.path.hasPrefix(aPath) }))
        defer { StoreFileWriter.uninstall() }
        _ = rootPath
        let transcript = Transcript.now(), executorsBefore = executors()
        func zeroWork(_ what: String, cacheWritesAllowed: Int) async throws {
            let trace = StoreFileWriter.trace
            let outsideCache = trace.filter { !$0.path.hasPrefix(sharedCache.hasPrefix("/private/") ? String(sharedCache.dropFirst(8)) : sharedCache) }
            let reports = await authority.usageReports
            try expect(Transcript.now() == transcript && executors() == executorsBefore && reports == 0
                && outsideCache.isEmpty && trace.count <= cacheWritesAllowed && trace.allSatisfy { !$0.path.hasSuffix("canvas.json") }
                && (try Data(contentsOf: source)) == sourceBytes,
                "\(what): zero transcript measurements, zero canvas saves, zero executor/model work, \(trace.count) shared-cache writes (≤ \(cacheWritesAllowed))\(outsideCache.isEmpty ? "" : " — unexpected \(outsideCache)")")
            _ = StoreFileWriter.uninstall()
            StoreFileWriter.install(.init(fault: .none, scope: root, matching: { !$0.standardizedFileURL.path.hasPrefix(aPath) }))
        }

        // 1. Presence flood from one teammate with usage reports.
        let cAt = { (i: Int) -> Collaboration.Point in .init(x: 60 + Double(i % 50) * 3, y: 60 + Double(i / 50) * 5) }
        func frame(_ i: Int) -> Collaboration.Presence {
            let usage = Collaboration.UsageSnapshot(host: .init(), sequence: UInt64(i), inputTokens: UInt64(i * 10), outputTokens: UInt64(i),
                todayInputTokens: UInt64(i * 10), todayOutputTokens: UInt64(i), dayUTC: SharedAreaUsageLedger.dayUTC(Date()),
                observedSince: Date(), measuredAt: Date(), coveredAgents: 1, runningAgents: 1, partial: false)
            return .init(identity: c, cursor: cAt(i), viewport: nil, expiresAt: Date().addingTimeInterval(60), label: "Peer C", usage: usage)
        }
        try await authority.setPresence(frame(0))
        try await Rig.eventually("first teammate cursor") { overlay.peers.contains { $0.identity.device == c.device } }
        overlay.inspect(device: nil); try await quiesce()
        var applied = 0
        let observer = modelB.addChangeObserver { applied += 1 }
        defer { modelB.removeChangeObserver(observer) }

        // 1a. Two hundred updates inside one display interval: the main thread
        // is held while the authority sends them all, as a burst of frames
        // landing between two screen refreshes would be.
        let burst = 200
        var overlayDraws = overlay.drawCount, cardDraws = overlay.cardDraws, banner = overlay.bannerMeasurements
        var contentDraws = sceneB.contentDrawCount
        CollaborationWorkCensus.watch([sceneB])
        let frames = (1...burst).map(frame)
        holdMainThread { for value in frames { try? await authority.setPresence(value) } }
        try await Rig.eventually("burst's last position reaches the client") {
            modelB.presence.first(where: { $0.identity.device == c.device })?.cursor == cAt(burst)
        }
        settle()
        let lastPoint = overlay.convert(sceneB.screenPoint(forAreaPoint: .init(x: cAt(burst).x, y: cAt(burst).y)), from: sceneB)
        // The connection keeps only the newest frame, so the burst lands as one
        // or two applied frames; the overlay then paints at most once for each.
        // Layer-backed views paint at the next commit, so wait for that paint.
        try await Rig.eventually("overlay paints the last position") { settle(); return overlay.drawnCursors[c.device] == lastPoint }
        let burstDraws = overlay.drawCount - overlayDraws
        try expect(applied <= 3 && burstDraws <= applied,
            "\(burst) updates in one display interval apply as \(applied) frame(s) and \(burstDraws) overlay paint(s), showing the last position")
        try expect(sceneB.contentDrawCount == contentDraws && CollaborationWorkCensus.layoutTotal == 0 && CollaborationWorkCensus.insertionTotal == 0,
            "the burst repaints no shared content, runs no layout pass and creates no view (\(CollaborationWorkCensus.layouts), \(CollaborationWorkCensus.insertions))")

        // 1b. The overlay itself coalesces: fifty teammate positions assigned
        // within one main-thread turn paint once, at the last one. (Through the
        // controller it never sees more than one per turn; see 1a.)
        try await quiesce()
        let coalesceDraws = overlay.drawCount
        let positions = (1...50).map { frame(burst + 400 + $0) }
        for value in positions { overlay.peers = [value] }
        let coalescedPoint = overlay.convert(sceneB.screenPoint(forAreaPoint: .init(x: cAt(burst + 450).x, y: cAt(burst + 450).y)), from: sceneB)
        try await Rig.eventually("overlay paints the coalesced position") { settle(); return overlay.drawnCursors[c.device] == coalescedPoint }
        try await quiesce()
        try expect(overlay.drawCount - coalesceDraws == 1,
            "50 cursor updates in one turn paint the overlay once (\(overlay.drawCount - coalesceDraws)), at the last position")

        // 1c. Fifty updates, each followed by a display pass.
        let paced = 50
        try await quiesce()
        overlayDraws = overlay.drawCount; contentDraws = sceneB.contentDrawCount; applied = 0
        CollaborationWorkCensus.watch([sceneB])
        for i in (burst + 1)...(burst + paced) {
            try await authority.setPresence(frame(i))
            try await Rig.eventually("paced frame \(i)") { modelB.presence.first(where: { $0.identity.device == c.device })?.cursor == cAt(i) }
            settle()
        }
        try expect(overlay.drawCount - overlayDraws <= paced && sceneB.contentDrawCount == contentDraws
            && CollaborationWorkCensus.layoutTotal == 0 && CollaborationWorkCensus.insertionTotal == 0,
            "\(paced) paced updates: ≤ 1 overlay paint each (\(overlay.drawCount - overlayDraws)), no content paint, no layout pass, no view")
        try expect(overlay.cardDraws == cardDraws && overlay.bannerMeasurements == banner && overlay.inspectedDevice == nil
            && modelB.presence.first(where: { $0.identity.device == c.device })?.usage?.sequence == UInt64(burst + paced),
            "usage advances to the latest report while closed hover paints no card and measures no text")
        try await zeroWork("presence flood", cacheWritesAllowed: 0)
        CollaborationWorkCensus.stop()

        // 2. Follow: B tracks twenty moves of A's view.
        func publishA(_ camera: SharedAreaLocalView) async throws {
            try sceneA.setCamera(camera)
            let bounds = sceneA.areaCanvasView.bounds
            let wanted = SharedArea.Rect(x: camera.x, y: camera.y, width: bounds.width / camera.zoom, height: bounds.height / camera.zoom)
            try await Rig.eventually("A's view published") {
                if modelB.presence.first(where: { $0.identity.device == a.device })?.viewport == wanted { return true }
                await publisherA.publishPointer(.init(x: 150, y: 120)); return false
            }
        }
        try await publishA(.init(x: 0, y: 0, zoom: 1))
        try expect(publisherB.follow(device: a.device), "the measured client follows its teammate")
        try await quiesce()
        _ = StoreFileWriter.uninstall()
        StoreFileWriter.install(.init(fault: .none, scope: root, matching: { !$0.standardizedFileURL.path.hasPrefix(aPath) }))
        let followWrites = sceneB.privateViewWrites, followDraws = sceneB.contentDrawCount, applies = publisherB.followCameraApplies
        CollaborationWorkCensus.watch([sceneB])
        let moves = 20
        for step in 1...moves {
            try await publishA(.init(x: Double(step) * 37, y: Double(step) * 21, zoom: 1 + Double(step % 3) * 0.2))
            try await Rig.eventually("follow frame \(step)") { publisherB.followCameraApplies == applies + step }
            settle()
        }
        try expect(sceneB.contentDrawCount - followDraws <= moves && CollaborationWorkCensus.insertionTotal == 0
            && CollaborationWorkCensus.layoutTotal == 0 && sceneB.privateViewWrites == followWrites,
            "\(moves) followed moves: ≤ 1 content paint each (\(sceneB.contentDrawCount - followDraws)), no layout pass, no view, no private camera write")
        try await zeroWork("follow", cacheWritesAllowed: 0)
        CollaborationWorkCensus.stop()
        publisherB.stopFollowing(notice: nil); settle()

        // 3. Agreement edits and 4. remote operations, each twenty frames.
        func measureRemote(_ what: String, events: Int, _ edit: (Int) throws -> [SharedArea.Edit], until: @escaping @MainActor () -> Bool) async throws {
            _ = StoreFileWriter.uninstall()
            StoreFileWriter.install(.init(fault: .none, scope: root, matching: { !$0.standardizedFileURL.path.hasPrefix(aPath) }))
            try await quiesce()
            let draws = sceneB.contentDrawCount
            CollaborationWorkCensus.watch([sceneB])
            var firstHalf = 0
            for index in 1...events {
                let revision = await authority.document.revision
                try await authority.remote(try edit(index))
                try await Rig.eventually("\(what) frame \(index)") { modelB.document?.revision == revision + 1 }
                settle()
                if index == events / 2 { firstHalf = CollaborationWorkCensus.layoutTotal }
            }
            try await Rig.eventually(what) { until() }
            let layouts = CollaborationWorkCensus.layoutTotal, secondHalf = layouts - firstHalf
            try expect(CollaborationWorkCensus.insertionTotal == 0 && CollaborationWorkCensus.appKitInsertionTotal <= events
                && layouts <= events * layoutPassesPerEvent
                && secondHalf <= firstHalf + layoutPassesPerEvent && sceneB.contentDrawCount - draws <= events,
                "\(events) \(what): no Array view created (AppKit text fragments \(CollaborationWorkCensus.appKitInsertionTotal) ≤ 1 each), \(layouts) layout passes (\(firstHalf) then \(secondHalf), ≤ \(layoutPassesPerEvent) each, flat), \(sceneB.contentDrawCount - draws) content paints (≤ 1 each) \(CollaborationWorkCensus.layouts) inserted \(CollaborationWorkCensus.insertions)")
            try await zeroWork(what, cacheWritesAllowed: events)
            CollaborationWorkCensus.stop()
        }
        var parent = first.id
        try await measureRemote("agreement revisions and endorsements", events: 20, { index in
            if index % 2 == 0 { return [.endorse(.init(revision: parent, person: a.person))] }
            let next = SharedArea.Context(id: .init(), object: agreement.id, parent: parent, author: a.person, text: "Revision \(index)")
            parent = next.id
            return [.context(next)]
        }, until: { sceneB.agreementPanel.summaryText.hasPrefix("Revision 11") })
        var rect = placement.rect
        try await measureRemote("remote moves and posts", events: 20, { index in
            if index % 2 == 0 { return [.post(.init(id: .init(), object: discussion.id, author: a.person, text: "Remote \(index)"))] }
            rect = .init(x: rect.x + 5, y: rect.y + 3, width: rect.width, height: rect.height)
            return [.place(.init(id: placement.id, object: discussion.id, rect: rect, z: placement.z))]
        }, until: { modelB.document?.posts.count == 10 })
        try expect((await authority.applies) == 0 && supervisor.records.isEmpty,
            "no budgeted traffic sent a shared operation or created an agent record")
        await modelA.close()
        try await liveViewRows()
        print("Collaboration budgets passed: presence flood, follow, agreement edits, remote operations and live agent rows counted on the production mount.")
    }

    /// A prompter that is never asked to send: the budget is the view's.
    private struct NoRoute: SharedAgentHandoffTransport {
        struct Unused: Error {}
        func state() async throws -> Collaboration.State { throw Unused() }
        func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { throw Unused() }
        func control(object: UUID) async throws -> Collaboration.AgentControlState { throw Unused() }
        func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { throw Unused() }
        func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { throw Unused() }
        func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
    }

    private final class ScriptedReads {
        var queue: [Collaboration.AgentProjection.Read]
        init(_ queue: [Collaboration.AgentProjection.Read]) { self.queue = queue }
        func next() -> Collaboration.AgentProjection.Read {
            queue.isEmpty ? .frames(generation: 1, frames: [], more: false) : queue.removeFirst()
        }
    }

    /// 5. Shared live view: one delta re-renders only the retained rows, so the
    /// work is the same whether the agent has produced 10, 100 or 1,000 rows.
    /// The projection keeps at most `maxRows`; the view never sees the rest.
    private static func liveViewRows() async throws {
        typealias P = Collaboration.AgentProjection
        let host = SharedArea.ID<SharedArea.Host>(), item = SharedArea.Item(id: .init(), kind: .agentObservation,
            source: .init(owner: .init(), host: host, binding: .init()))
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 40, y: 40, width: 420, height: 300)))]))
        let capabilities = P.Capabilities(locallyManaged: true, canSend: false, canQueue: true, canSteer: true, canInterrupt: true)
        let root = try Rig.root("live-rows")
        defer { try? FileManager.default.removeItem(at: root) }
        let me = Collaboration.Identity(person: .init(), device: UUID())
        let model = try Rig.controller(root: root, identity: me, label: "You",
            authority: Rig.Authority(document: document, members: [(me, .editor)]), seed: (document, .editor))
        // Watching, and with full access: the composer a teammate prompts from
        // must not make a projection delta cost more.
        for prompts in [false, true] {
        // A role is what offers the composer; the watch-only pass never asks.
        if prompts { await model.open() }
        var measured: [(rows: Int, layouts: Int, appKit: Int, rendered: Int, omitted: Int)] = []
        for count in [10, 100, 1_000] {
            func frame(_ sequence: Int, _ payload: P.Payload) -> P.Frame {
                .init(host: host, object: item.id, generation: 1, sequence: UInt64(sequence), payload: payload)
            }
            var snapshot = P.Snapshot(host: host, object: item.id, generation: 1, history: .assistantOutput, phase: .working, capabilities: capabilities)
            for index in 1...count { try snapshot.apply(frame(index, .assistantText(row: "r\(index)", turn: "t", delta: "Row \(index) of the agent's answer."))) }
            let reads = ScriptedReads([.resnapshot(snapshot)])
            let view = SharedAgentLiveView(controller: model, read: { _, _ in reads.next() })
            let window = NSView(frame: .init(x: 0, y: 0, width: 520, height: 420))
            view.frame = window.bounds; window.addSubview(view)
            // The composer is Auto Layout inside; a real (never shown) window
            // keeps one engine, as on the canvas. A bare view tree builds a
            // temporary engine per pass and re-lays out every constrained view.
            let host = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: true)
            if prompts { host.contentView = window }
            defer { view.stop(); host.contentView = nil }
            if prompts {
                view.prompter = try SharedAgentHandoffController(identity: me, transport: NoRoute(),
                    directory: root.appendingPathComponent("prompter-\(count)", isDirectory: true))
            }
            view.show(object: item.id, in: document)
            try await Rig.eventually("live view takes the \(count)-row snapshot", attempts: 1_000) { view.replica.state?.through == UInt64(count) }
            window.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try expect(view.offersComposer == prompts, "the live view offers its composer exactly when it has a route (\(prompts))")
            if prompts {
                // The composer's own setup (draft restore, first measurement)
                // finishes on later turns; the budget is one delta, not that.
                try await Task.sleep(for: .milliseconds(100))
                window.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            }
            CollaborationWorkCensus.watch([window])
            reads.queue.append(.frames(generation: 1, frames: [frame(count + 1, .assistantText(row: "r\(count)", turn: "t", delta: " More."))], more: false))
            try await Rig.eventually("live view applies one delta over \(count) rows", attempts: 1_000) { view.replica.state?.through == UInt64(count + 1) }
            window.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let state = view.replica.state!
            try expect(CollaborationWorkCensus.insertionTotal == 0 && view.transcriptText.hasSuffix("answer. More."),
                "one delta over \(count) rows: the changed row shows, no Array view created")
            let appKitLayouts = CollaborationWorkCensus.layouts.filter { $0.key.hasPrefix("_") }.values.reduce(0, +)
            measured.append((count, CollaborationWorkCensus.layoutTotal - appKitLayouts, appKitLayouts,
                view.transcriptText.components(separatedBy: "\n\n").count - (state.omittedRows > 0 ? 1 : 0), state.omittedRows))
            CollaborationWorkCensus.stop()
        }
        let layouts = measured.map(\.layouts), appKit = measured.map(\.appKit), rendered = measured.map(\.rendered)
        try expect(rendered[0] == 10 && rendered[1] == P.maxRows && rendered[2] == P.maxRows
            && measured[2].omitted == 1_000 - P.maxRows && layouts.max()! <= layouts.min()! + 1 && layouts.max()! <= layoutPassesPerEvent
            && appKit[1] == appKit[2] && appKit.max()! <= P.maxRows,
            "live view delta\(prompts ? " with the composer" : "") is flat across 10 / 100 / 1,000 rows: renders \(rendered) rows (≤ \(P.maxRows) retained), \(layouts) Array layout passes, \(appKit) TextKit fragment layouts (visible rows only)")
        }
    }

    /// Runs `work` to completion off the main thread while the main thread
    /// waits, so everything it sends lands inside one main-thread turn.
    private nonisolated static func holdMainThread(_ work: @escaping @Sendable () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task.detached { await work(); done.signal() }
        done.wait()
    }
}
