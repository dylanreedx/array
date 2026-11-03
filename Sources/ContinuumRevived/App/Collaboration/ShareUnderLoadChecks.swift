import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// `--share-under-load-check`: Share keeps working when the relay is slow and
/// the shared agent is big, against a local `continuum-relay`.
///
/// In 0.7.40 a lead with 32 helpers published 33 transcript streams of up to
/// 176 KiB each into a relay that holds 4 MiB per shared agent. Each new
/// checkpoint evicted another stream, whose publisher checkpointed again every
/// 250 ms, and the churn never stopped. On production that held a 1-vCPU relay
/// at 1-13 s per request. Every account request then held the account's
/// one-at-a-time lane for seconds. Share waited 4 s for it, failed with
/// "Another collaboration action is still running", and undid itself.
///
/// 1. A transcript upload the relay refuses (a forced 413) backs off. The
///    error stays on the publisher, and the next accepted tick clears it.
/// 2. A lead with a several-MB transcript and 32 helpers, shared through the
///    header Share and Copy: the link is minted, the streams settle (no
///    checkpoint is sent while nothing changes), and a guest who opens the link
///    reads the transcript's tail.
/// 3. With the account lane held by the background access read on a slow
///    relay, a second Share waits its turn and mints its link. Copy on a live
///    link is local: it copies while that lane is held and the uploads run.
/// 4. A link the relay refuses with 413: the popover says so, the lane is
///    released, nothing stays shared, and the next Copy shares.
@MainActor
enum ShareUnderLoadChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: "share under load: " + label) }
        print("PASS share under load: \(label)")
    }
    /// A witness's own claim: reported, and the run goes on, so one RED run
    /// shows every leg. `run` fails at the end if any did.
    private static var failures: [String] = []
    private static func check(_ condition: Bool, _ label: String) {
        if condition { print("PASS share under load: \(label)") }
        else { failures.append(label); print("FAIL share under load: \(label)") }
    }
    private static func eventually(_ label: String, timeout: TimeInterval = 30, _ value: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if value() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "share under load: timeout: \(label)")
    }

    // MARK: A slow relay, and refusals on demand

    /// What the account transport does to the real one's requests.
    final class Faults: @unchecked Sendable {
        private let lock = NSLock()
        private var _accessDelay: Duration = .zero
        private var _mintRefusals = 0
        var accessDelay: Duration {
            get { lock.withLock { _accessDelay } }
            set { lock.withLock { _accessDelay = newValue } }
        }
        var mintRefusals: Int {
            get { lock.withLock { _mintRefusals } }
            set { lock.withLock { _mintRefusals = newValue } }
        }
        func takeMintRefusal() -> Bool {
            lock.withLock { guard _mintRefusals > 0 else { return false }; _mintRefusals -= 1; return true }
        }
    }

    /// The production transport, with the access read slowed as a busy relay
    /// slows it, and link creation refused with 413 when asked.
    struct FaultyTransport: CollaborationAccountTransport {
        let base: any CollaborationAccountTransport
        let faults: Faults
        func redeem(code: String, deviceLabel: String) async throws -> Collaboration.Credential { try await base.redeem(code: code, deviceLabel: deviceLabel) }
        func identity() async throws -> Collaboration.Identity { try await base.identity() }
        func createArea() async throws -> Collaboration.State { try await base.createArea() }
        func state(area: UUID) async throws -> Collaboration.State { try await base.state(area: area) }
        func accept(code: String) async throws -> Collaboration.Scope { try await base.accept(code: code) }
        func invite(area: UUID, person: SharedArea.ID<SharedArea.Person>, role: Collaboration.Role) async throws -> Collaboration.Invitation {
            try await base.invite(area: area, person: person, role: role)
        }
        func registerHost() async throws -> Collaboration.Host { try await base.registerHost() }
        func createShareLink(area: UUID, request: Collaboration.ShareLinkRequest) async throws -> Collaboration.ShareLink {
            if faults.takeMintRefusal() { throw CollaborationClientError.server(status: 413, code: "payloadTooLarge") }
            return try await base.createShareLink(area: area, request: request)
        }
        func acceptShareLink(slug: String, token: String) async throws -> Collaboration.Scope { try await base.acceptShareLink(slug: slug, token: token) }
        func shareLinks(area: UUID) async throws -> [Collaboration.ShareLinkAccess] {
            let delay = faults.accessDelay
            if delay > .zero { try await Task.sleep(for: delay) }
            return try await base.shareLinks(area: area)
        }
        func revokeShareLink(area: UUID, link: UUID) async throws { try await base.revokeShareLink(area: area, link: link) }
        func removeShareLinkPerson(area: UUID, link: UUID, person: UUID) async throws {
            try await base.removeShareLinkPerson(area: area, link: link, person: person)
        }
        func joinShareLink(_ request: Collaboration.JoinShareLink) async throws -> Collaboration.ShareLinkJoin { try await base.joinShareLink(request) }
        func selfEnroll(_ request: Collaboration.SelfEnroll) async throws -> Collaboration.Credential { try await base.selfEnroll(request) }
    }

    /// Refuses every upload the way an over-budget relay does.
    final class RefusingSink: SharedAgentTranscriptSink {
        var attempts = 0
        var refusing = true
        func publish(stream: String, checkpoint: Collaboration.AgentTranscript.Checkpoint?,
                     frames: [Collaboration.AgentTranscript.Frame]) async throws {
            attempts += 1
            if refusing { throw CollaborationClientError.server(status: 413, code: "payloadTooLarge") }
        }
    }

    // MARK: Run

    static func run() async throws {
        failures = []
        try await refusedUploadsBackOff()
        try await shareUnderLoad()
        guard failures.isEmpty else { throw Failure(description: "share under load: " + failures.joined(separator: "; ")) }
        print("Share under load checks passed: refused uploads back off, a big agent's streams settle and its guest reads the tail, a share waits out a slow relay's lane, Copy stays local, and a refused link says so and releases the lane.")
    }

    /// Finished turns, `turns` of them, with replies of `replyBytes`.
    static func grow(_ supervisor: AgentSupervisor, _ id: AgentID, turns: Int, replyBytes: Int, tag: String) {
        let thread = AgentSupervisor.threadId(for: id)
        let reply = String(repeating: "Checkout state validates, then authorises. ", count: max(1, replyBytes / 44))
        for turn in 0..<turns {
            let t = "\(tag)\(turn)"
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: t), to: id)
            supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "c" + t, kind: .commandExecution, title: "rg -n state Sources/Checkout"), to: id)
            supervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: "c" + t, kind: .commandExecution, status: .completed), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .assistant, delta: "Turn \(t). " + reply), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: t, outcome: .completed, errorMessage: nil), to: id)
        }
    }

    /// 1. The publisher's own loop, on a sink that always says 413.
    static func refusedUploadsBackOff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("share-under-load-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let id = AgentID(rawValue: UUID())
        try store.upsert(AgentRecord(id: id, displayName: "Long", harness: .pi, model: AgentCatalogQAFixture.pi[0],
                                     thinking: "none", cwd: root.path, projectId: UUID(), createdAt: Date(), lastActivityAt: Date()))
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        _ = supervisor.restore()
        grow(supervisor, id, turns: 200, replyBytes: 2_000, tag: "r")
        let sink = RefusingSink()
        let publisher = SharedAgentTranscriptPublisher(supervisor: supervisor, agent: id, generation: 1, sink: sink)
        publisher.start()
        try await Task.sleep(for: .seconds(6))
        publisher.stop()
        // At the old 250 ms retry, 6 s is ~24 attempts; backing off 1, 2, 4 s is 4.
        check(sink.attempts >= 2 && sink.attempts <= 5,
            "a refused upload backs off instead of resending a checkpoint every tick (\(sink.attempts) attempts in 6 s)")
        var kept = false
        if case .server(413, _)? = publisher.lastError as? CollaborationClientError { kept = true }
        check(kept, "the publisher keeps the relay's 413 as its error (\(String(describing: publisher.lastError)))")
        sink.refusing = false
        await publisher.tick()
        check(publisher.lastError == nil && publisher.checkpoints == 1,
            "once the relay accepts, one checkpoint goes and the error clears")
    }

    /// 2-4. The production share, end to end, against a local relay.
    static func shareUnderLoad() async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "isolated app support required")
        }
        let root = URL(fileURLWithPath: support).appendingPathComponent("share-under-load-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let relay = try ShareEntryRelayChecks.Relay(root: root.appendingPathComponent("relay"))
        defer { relay.stop() }
        try await relay.start()

        let scene = try ShareEntryChecks.mountScene("share-under-load", transcripts: true)
        defer { scene.close() }
        let canvas = scene.canvas, app = scene.app, window = scene.window
        let agentA = TileInsertSlideChecks.tileA, agentB = TileInsertSlideChecks.tileB, agentD = TileInsertSlideChecks.tileD
        let lead = scene.agents[0]
        let supervisor = app.agentSupervisor

        // The lead: a several-MB transcript and 32 helpers with long ones.
        grow(supervisor, lead, turns: 1_500, replyBytes: 3_000, tag: "l")
        guard let leadDocument = supervisor.transcriptDocument(for: lead) else { throw Failure(description: "share under load: no lead document") }
        let leadBytes = try SharedAgentTranscriptWire.encode(leadDocument.entries).count
        try expect(leadBytes > 3_000_000, "the lead's transcript is several MB (\(leadBytes) bytes, \(leadDocument.entries.count) entries)")
        guard let leadRecord = supervisor.records[lead] else { throw Failure(description: "share under load: no lead record") }
        var helpers: [AgentID] = []
        for n in 0..<SharedAgentTranscriptWire.maxHelpers {
            let helper = supervisor.spawn(role: nil, prompt: nil, cwd: URL(fileURLWithPath: leadRecord.cwd), harness: .claudeCode,
                                          model: "fixture/share", thinking: "medium", projectId: leadRecord.projectId,
                                          parentAgentID: lead, displayName: "Helper \(n)")
            grow(supervisor, helper, turns: 70, replyBytes: 3_000, tag: "h\(n)-")
            helpers.append(helper)
        }
        try expect(SharedAgentHelpers.roster(supervisor, lead: lead).count == SharedAgentTranscriptWire.maxHelpers,
            "the lead's roster names \(SharedAgentTranscriptWire.maxHelpers) helpers")

        let faults = Faults()
        let endpoint = try CollaborationServiceEndpoint(URL(string: "http://127.0.0.1:\(relay.port)")!, allowsInsecureLoopback: true)
        let account = try CollaborationAccountController(
            store: .init(applicationSupportRoot: root.appendingPathComponent("account"), bundleIdentifier: nil),
            credentialStore: .init(vault: SharedAreaCheckRig.MemoryVault(), bundleIdentifier: nil), bundleIdentifier: nil,
            transportFactory: { endpoint, credential in
                FaultyTransport(base: try CollaborationAccountController.liveTransport(endpoint: endpoint, credential: credential), faults: faults)
            })
        app.qaAdoptCollaborationAccount(account)
        app.qaAttachWindowForOfflineCheck(window)
        app.shareLinks.defaultEndpoint = { endpoint }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arrayapp.share-under-load.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        app.qaInstallShareEntry(pasteboard: pasteboard)
        app.shareEntry.presentsOffscreenForQA = true
        func answerNameSheet(_ name: String) {
            guard let sheet = window.attachedSheet,
                  let field = ShareEntryRelayChecks.views(NSTextField.self, in: sheet.contentView).first(where: { $0.accessibilityLabel() == "Your name" }),
                  let button = ShareEntryRelayChecks.views(NSButton.self, in: sheet.contentView).first(where: { $0.title == "Continue" }) else { return }
            field.stringValue = name
            button.performClick(nil)
        }
        func share(_ tile: UUID) throws -> ShareLinkPopoverView {
            canvas.centerOnTile(tile)
            canvas.layoutSubtreeIfNeeded()
            guard let view = canvas.tileView(for: tile), let button = view.qaTitleBarShareControl else {
                throw Failure(description: "share under load: \(tile) shows no header Share")
            }
            try ShareEntryChecks.click(button, drawnIn: view.qaTitleBarView)
            guard app.shareEntry.isPresented, let popover = app.shareEntry.presentedView else {
                throw Failure(description: "share under load: the header Share opened no popover")
            }
            popover.layoutSubtreeIfNeeded()
            return popover
        }
        /// The popover can close itself while a check waits (a tile mark
        /// relayouts its anchor); Share on the same tile reopens its session.
        func reopened(_ popover: ShareLinkPopoverView, _ tile: UUID) throws -> ShareLinkPopoverView {
            guard popover.window == nil else { return popover }
            print("note: the popover closed itself (\(app.shareEntry.qaLastSelfDismissal ?? "no reason")); reopening")
            let again = try share(tile)
            try expect(again.session === popover.session, "Share on the same tile reopens the same session")
            return again
        }
        func settle(_ popover: ShareLinkPopoverView, timeout: TimeInterval = 120) async throws {
            // A retry's popover still shows the last failure until its share starts.
            try await eventually("the share starts", timeout: 5) { popover.session.isWorking || popover.session.link != nil || popover.session.failure == nil }
            try await eventually("the share settles", timeout: timeout) {
                answerNameSheet("QA Dylan")
                return !popover.session.isWorking && (popover.session.phase != .draft || popover.session.failure != nil)
            }
        }

        // 2. Share the big lead.
        let popoverA = try share(agentA)
        try ShareEntryChecks.click(popoverA.copyButton)
        try await settle(popoverA)
        guard let linkA = popoverA.session.link, let areaA = popoverA.session.area else {
            throw Failure(description: "share under load: sharing the big agent made no link (\(popoverA.session.failure ?? ""))")
        }
        try expect(pasteboard.string(forType: .string) == linkA.url.absoluteString, "sharing a several-MB agent with 32 helpers mints and copies its link")
        app.shareEntry.dismiss()
        guard let account0 = account.activeAccount?.id, let host = app.sharedAreaHostSessions[account0 + "/" + areaA.uuidString] else {
            throw Failure(description: "share under load: this Mac does not host the shared lead")
        }
        try await eventually("the lead's stream and its helpers' start", timeout: 30) {
            (host.projections?.transcripts.values.first?.checkpoints ?? 0) > 0 && !(host.projections?.helperTranscripts.isEmpty ?? true)
        }
        // Let the first checkpoints land. Then the lead and every helper stream
        // a reply, as a working lead's do: only then does a stream the relay
        // evicted find out, and checkpoint again.
        try await Task.sleep(for: .seconds(6))
        func publishers() -> [SharedAgentTranscriptPublisher] {
            guard let projections = host.projections else { return [] }
            return Array(projections.transcripts.values) + projections.helperTranscripts.values.flatMap { Array($0.values) }
        }
        let working = [lead] + helpers
        for id in working { supervisor.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: id), turnId: "live"), to: id) }
        let before = publishers().reduce(0) { $0 + $1.checkpoints }
        var refused = 0
        for round in 0..<16 {
            for id in working {
                supervisor.qaDeliver(.contentDelta(threadId: AgentSupervisor.threadId(for: id), turnId: "live", streamKind: .assistant,
                                                   delta: "Round \(round): authorising, then paid or declined. "), to: id)
            }
            try await Task.sleep(for: .milliseconds(500))
            refused += publishers().filter { $0.lastError != nil }.count
        }
        let after = publishers().reduce(0) { $0 + $1.checkpoints }
        check(after == before && refused == 0,
            "while the lead and its helpers stream for 8 s, the \(publishers().count) streams send patches only: no checkpoint is resent and none is refused (\(after - before) checkpoints resent, \(refused) refusals seen)")
        for id in working {
            supervisor.qaDeliver(.turnCompleted(threadId: AgentSupervisor.threadId(for: id), turnId: "live", outcome: .completed, errorMessage: nil), to: id)
        }
        try await Task.sleep(for: .seconds(2))

        // A guest opens the link and reads the transcript's tail.
        let guest = try CollaborationAccountController(
            store: .init(applicationSupportRoot: root.appendingPathComponent("guest"), bundleIdentifier: nil),
            credentialStore: .init(vault: SharedAreaCheckRig.MemoryVault(), bundleIdentifier: nil), bundleIdentifier: nil)
        var openedArea: UUID?
        let opener = ShareLinkOpener(account: guest, signIn: { _ in false }, askName: { _, _ in "Sam" },
                                     open: { state, _ in openedArea = state.document.id.rawValue },
                                     deviceLabel: "QA Sam's Mac", allowsInsecureLoopback: true)
        let outcome = await opener.open(linkA.url)
        try expect(outcome == .opened(area: areaA) && openedArea == areaA, "the guest's link opens the shared lead")
        let guestController = try guest.makeSharedAreaController(area: areaA)
        await guestController.open()
        defer { Task { await guestController.close() } }
        guard let object = guestController.document?.items.first(where: { $0.kind == .agentObservation })?.id else {
            throw Failure(description: "share under load: the guest sees no shared agent")
        }
        var mirror = SharedAgentTranscriptWire.Mirror()
        var tail = "no read"
        var checkpointBytes = Int.max
        do {
            let read = try await guestController.readAgentTranscript(object: object, request: .init(
                stream: Collaboration.AgentTranscript.mainStream, cursor: nil, waitMilliseconds: 0))
            if case let .resnapshot(checkpoint, frames, _) = read {
                checkpointBytes = checkpoint.body.count
                _ = try mirror.install(SharedAgentTranscriptWire.decode(SharedAgentTranscriptWire.Checkpoint.self, from: checkpoint.body))
                for frame in frames {
                    if let patch = try? SharedAgentTranscriptWire.decode(SharedAgentTranscriptWire.Patch.self, from: frame.body) { _ = try? mirror.apply(patch) }
                }
                tail = "\(mirror.document.entries.count) entries, \(mirror.omittedEntries) older left out, \(checkpointBytes) bytes"
            } else { tail = "the first read is not a checkpoint" }
        } catch { tail = "the read failed: \(error)" }
        let hostTail = supervisor.transcriptDocument(for: lead)?.entries.last?.id
        check(mirror.document.entries.last?.id == hostTail && mirror.omittedEntries > 0 && checkpointBytes <= Collaboration.AgentTranscript.maxCheckpointBytes,
            "the guest renders the transcript's tail from one bounded checkpoint (\(tail))")

        // 3. The background access read holds the lane on a slow relay.
        faults.accessDelay = .seconds(6)
        let read1 = Task { await app.refreshHostedAgentPeople() }
        try await eventually("the background access read holds the account") { account.isBusy }
        let popoverB = try share(agentB)
        try ShareEntryChecks.click(popoverB.copyButton)
        try await settle(popoverB)
        check(popoverB.session.failure == nil && popoverB.session.link != nil,
            "a Share that meets the background access read on a slow relay waits its turn and mints its link (\(popoverB.session.failure ?? ""))")
        await read1.value
        if popoverB.session.link == nil {
            // So the next claim runs even where this one failed: share B on a quiet lane.
            faults.accessDelay = .zero
            let retry = try reopened(popoverB, agentB)
            try ShareEntryChecks.click(retry.copyButton)
            try await settle(retry)
            faults.accessDelay = .seconds(6)
        }
        guard let linkB = popoverB.session.link else { throw Failure(description: "share under load: B never shared (\(popoverB.session.failure ?? ""))") }
        // Copy on that live link, with the lane held again and the lead's uploads running.
        let read2 = Task { _ = try? await app.shareLinks.listAccess(area: areaA) }
        try await eventually("the access read holds the account again") { account.isBusy }
        // The popover may have closed itself meanwhile; Share on the shared
        // tile reopens the same session, holding the same link.
        let copyFrom = try reopened(popoverB, agentB)
        pasteboard.clearContents()
        let pressed = Date()
        try ShareEntryChecks.click(copyFrom.copyButton)
        try await eventually("Copy copies", timeout: 1) { pasteboard.string(forType: .string) == linkB.url.absoluteString }
        check(Date().timeIntervalSince(pressed) < 0.5 && account.isBusy && popoverB.session.failure == nil,
            "Copy on a live link copies at once, while the account lane is held and the uploads run")
        app.shareEntry.dismiss()
        await read2.value
        faults.accessDelay = .zero

        // 4. The relay refuses the link with 413.
        faults.mintRefusals = 1
        let popoverD = try share(agentD)
        try ShareEntryChecks.click(popoverD.copyButton)
        try await settle(popoverD)
        check(popoverD.session.failure != nil && popoverD.session.link == nil && !account.isBusy
            && app.hostedAgentArea(forTile: agentD) == nil && popoverD.copyButton.presentation.isEnabled,
            "a link refused with 413 is shown (\(popoverD.session.failure ?? "")), releases the account and leaves nothing shared")
        let retryD = try reopened(popoverD, agentD)
        try ShareEntryChecks.click(retryD.copyButton)
        try await settle(retryD)
        check(popoverD.session.failure == nil && popoverD.session.link != nil && app.hostedAgentArea(forTile: agentD) != nil,
            "the next Copy shares (\(popoverD.session.failure ?? "no failure"))")
        app.shareEntry.dismiss()
    }
}
