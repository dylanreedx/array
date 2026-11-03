import AppKit
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCore

/// `--share-copy-latency-check`: what pressing Copy link costs, on the real
/// share action against the local relay (`ShareEntryRelayChecks.Relay`) through
/// `RelayLatencyProxy`, which counts and times every relay request, adds a
/// wide-area round trip, and holds requests on demand.
///
/// Each case presses the production popover's Copy button and records: when the
/// button first showed a pending state, when the pasteboard changed and to what,
/// when the button said Copied, the longest main-thread gap (a 4 ms heartbeat),
/// and the relay requests the press made. Cases: the first share on this Mac,
/// a second agent, an agent with a long transcript, a live note, Copy again on a
/// live link, New link on an area shared before a relaunch, and a reshare after
/// Revoke with the link mint held.
@MainActor
enum ShareCopyLatencyChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// A wide-area round trip, added to every relay request.
    static let roundTrip: TimeInterval = 0.06

    struct Sample {
        var label: String
        var pendingMs: Double?
        var pendingTitle: String = ""
        var pasteboardMs: Double?
        var copiedMs: Double?
        var doneMs: Double = 0
        var maxMainGapMs: Double = 0
        var requests: [RelayLatencyProxy.Request] = []
        // Existing hosts keep polling their streams independently of Copy.
        var accountRequests: [RelayLatencyProxy.Request] {
            requests.filter { $0.line.contains("/self ") || $0.line.contains("/links ") || $0.line.hasPrefix("POST /collaboration/v1/areas ") }
        }
        var copiedBeforePasteboard = false
        var pasted: String?
        var failure: String?
        var line: String {
            func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
            let relay = requests.compactMap(\.seconds).reduce(0, +) * 1000
            return "METRIC share-copy \(label): pending=\(f(pendingMs))ms('\(pendingTitle)') pasteboard=\(f(pasteboardMs))ms copied=\(f(copiedMs))ms "
                + "done=\(f(doneMs))ms main-gap-max=\(f(maxMainGapMs))ms requests=\(requests.count) relay-time=\(f(relay))ms"
        }
    }

    static func run() async throws -> String {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { failures.append(message()) } }

        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(description: "isolated app support required")
        }
        let root = URL(fileURLWithPath: support).appendingPathComponent("share-copy-latency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let relay = try ShareEntryRelayChecks.Relay(root: root.appendingPathComponent("relay"))
        defer { relay.stop() }
        try await relay.start()
        let proxy = try RelayLatencyProxy(upstreamPort: relay.port)
        defer { proxy.stop() }

        let scene = try ShareEntryChecks.mountScene("share-copy-latency", transcripts: true)
        defer { scene.close() }
        let canvas = scene.canvas, app = scene.app, window = scene.window
        let agentA = TileInsertSlideChecks.tileA, agentB = TileInsertSlideChecks.tileB
        let noteC = TileInsertSlideChecks.tileC, agentD = TileInsertSlideChecks.tileD

        // A long transcript on D: 1,100 entries, as the publisher perf check.
        let bigAgent = scene.agents[2]
        let thread = AgentSupervisor.threadId(for: bigAgent)
        let prose = String(repeating: "Checkout state validates against the saved card. ", count: 6)
        var turn = 0
        while (app.agentSupervisor.transcriptDocument(for: bigAgent)?.entries.count ?? 0) < 1_100 {
            guard turn < 500 else { throw Failure(description: "large transcript fixture did not grow") }
            turn += 1
            let t = "h\(turn)"
            app.agentSupervisor.qaDeliver(.turnStarted(threadId: thread, turnId: t), to: bigAgent)
            app.agentSupervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .reasoning, delta: prose), to: bigAgent)
            app.agentSupervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, title: "rg -n state Sources/Checkout"), to: bigAgent)
            app.agentSupervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, status: .completed), to: bigAgent)
            app.agentSupervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .assistant, delta: prose + prose), to: bigAgent)
            app.agentSupervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: t, outcome: .completed, errorMessage: nil), to: bigAgent)
        }
        let bigEntries = app.agentSupervisor.transcriptDocument(for: bigAgent)?.entries.count ?? 0

        let endpoint = try CollaborationServiceEndpoint(URL(string: "http://127.0.0.1:\(proxy.port)")!, allowsInsecureLoopback: true)
        let account = try CollaborationAccountController(
            store: .init(applicationSupportRoot: root.appendingPathComponent("account"), bundleIdentifier: nil),
            credentialStore: .init(vault: SharedAreaCheckRig.MemoryVault(), bundleIdentifier: nil), bundleIdentifier: nil)
        app.qaAdoptCollaborationAccount(account)
        app.qaAttachWindowForOfflineCheck(window)
        app.shareLinks.defaultEndpoint = { endpoint }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.arrayapp.share-copy-latency.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        app.qaInstallShareEntry(pasteboard: pasteboard)
        app.shareEntry.presentsOffscreenForQA = true
        // Signed in already: the delay Dylan sees is not the first-run name sheet.
        guard try await account.ensureAccount(defaultEndpoint: endpoint, deviceLabel: "QA Mac", askName: { _ in "QA Dylan" }) else {
            throw Failure(description: "share copy latency: could not sign in at the local relay")
        }
        proxy.setDelay(roundTrip)

        func share(_ tile: UUID) throws -> ShareLinkPopoverView {
            guard let view = canvas.tileView(for: tile) else {
                throw Failure(description: "share copy latency: missing tile \(tile)")
            }
            if let button = view.qaTitleBarShareControl {
                try ShareEntryChecks.click(button, drawnIn: view.qaTitleBarView)
            } else {
                // Live notes use the same production Share action without an
                // agent-only header control. Copy still traverses the real UI.
                app.shareAgentTile(view)
            }
            guard app.shareEntry.isPresented, let popover = app.shareEntry.presentedView else {
                throw Failure(description: "share copy latency: the header Share opened no popover")
            }
            popover.layoutSubtreeIfNeeded()
            return popover
        }

        /// Press Copy (or New link) and watch until the press has settled.
        func measure(_ label: String, _ popover: ShareLinkPopoverView, extraClicks: Int = 0,
                     whileWorking: ((Double) async -> Void)? = nil) async throws -> Sample {
            var sample = Sample(label: label)
            let session = popover.session
            let startCount = proxy.count
            let changeBefore = pasteboard.changeCount
            let titleBefore = popover.copyButton.presentation.title
            var lastBeat = Date()
            var maxGap: TimeInterval = 0
            let heartbeat = Timer(timeInterval: 0.004, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let now = Date(); maxGap = max(maxGap, now.timeIntervalSince(lastBeat)); lastBeat = now
                }
            }
            RunLoop.main.add(heartbeat, forMode: .common)
            defer { heartbeat.invalidate() }
            let start = Date()
            func ms() -> Double { Date().timeIntervalSince(start) * 1000 }
            try ShareEntryChecks.click(popover.copyButton)
            for _ in 0..<extraClicks { try ShareEntryChecks.click(popover.copyButton) }
            let deadline = Date().addingTimeInterval(30)
            var calledWhileWorking = false
            var pressedCopyAfterMint = false
            while Date() < deadline {
                let presentation = popover.copyButton.presentation
                if sample.pendingMs == nil, presentation.title != titleBefore || presentation.isLoading {
                    sample.pendingMs = ms(); sample.pendingTitle = presentation.title
                }
                if sample.pasteboardMs == nil, pasteboard.changeCount != changeBefore {
                    sample.pasteboardMs = ms(); sample.pasted = pasteboard.string(forType: .string)
                }
                // A button already reading Copied counts once the press has written.
                if sample.copiedMs == nil, presentation.title == "Copied", titleBefore != "Copied" || sample.pasteboardMs != nil {
                    sample.copiedMs = ms()
                    if sample.pasteboardMs == nil { sample.copiedBeforePasteboard = true }
                }
                if session.isWorking, !calledWhileWorking, let whileWorking {
                    calledWhileWorking = true
                    await whileWorking(ms())
                }
                // New link deliberately mints without copying. Measure the following
                // real Copy press too, and never mistake minting for a clipboard write.
                if titleBefore == "New link", !pressedCopyAfterMint, !session.isWorking,
                   session.link != nil, session.failure == nil, !session.copied {
                    pressedCopyAfterMint = true
                    try ShareEntryChecks.click(popover.copyButton)
                }
                if !session.isWorking, sample.copiedMs != nil || session.failure != nil { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            sample.doneMs = ms()
            sample.maxMainGapMs = max(maxGap, Date().timeIntervalSince(lastBeat)) * 1000
            sample.failure = session.failure
            // Let trailing host traffic land, then keep only what the press made.
            sample.requests = Array(proxy.requests[startCount...]).filter { $0.sent.timeIntervalSince(start) * 1000 <= sample.doneMs }
            print(sample.line)
            for request in sample.requests {
                print(String(format: "  +%5.0fms %4.0fms  %@", request.sent.timeIntervalSince(start) * 1000,
                             (request.seconds ?? -1) * 1000, request.line))
            }
            return sample
        }

        func capture(_ name: String, _ popover: ShareLinkPopoverView) throws {
            guard let path = ProcessInfo.processInfo.environment["ARRAY_SHARE_LATENCY_OUT"] else { return }
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { popover.session.onChange = { [weak popover] in popover?.render() } }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let copy = ShareLinkPopoverView(session: popover.session)
                let size = copy.preferredSize
                let probe = try UIProbe.render(.init(id: "share-copy." + name,
                    size: NSSize(width: size.width + 32, height: size.height + 32), appearance: appearance), make: { copy })
                if let png = probe.hostRep.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent(name + (appearance == .aqua ? "-light.png" : "-dark.png")))
                }
            }
        }

        func expectCopied(_ s: Sample, link: Collaboration.ShareLink?) {
            expect(s.failure == nil, "\(s.label): Copy failed (\(s.failure ?? ""))")
            expect(s.pasted != nil && s.pasted == link?.url.absoluteString,
                   "\(s.label): the pasteboard holds \(s.pasted ?? "nothing"), not the session's link")
            expect(!s.copiedBeforePasteboard, "\(s.label): the button said Copied before the link reached the pasteboard")
            expect((s.pasteboardMs ?? 1e9) <= 100 || s.pendingMs.map { $0 <= 100 } ?? false,
                   "\(s.label): the button showed no pending state within 100 ms of the press (\(s.pendingMs.map { "\(Int($0)) ms" } ?? "never"))")
        }

        let fakeLinks = ShareEntryChecks.FakeLinks(), fakeZones = ShareEntryChecks.FakeZones()
        let fake = ShareLinkSession(target: ShareTarget(workspaceID: UUID(), origin: .agent,
            items: [.init(key: .init(projectID: UUID(), tileID: UUID()), title: "Rename test", kind: .managedAgent)]),
            links: fakeLinks, zones: fakeZones, pasteboard: pasteboard)
        await fake.copy()
        let originalArea = fake.area
        fake.setSlug("renamed-link")
        await fake.copy()
        expect(fake.area == originalArea && fakeZones.agentShares.count == 1 && fakeLinks.revoked.count == 1,
               "renamed-link: changing the slug must replace the link on the same host")

        // A relay refusal after revoking the old link must leave a retryable
        // link state, never a copyable token that the relay has already revoked.
        fake.setSlug("retry-link")
        fakeLinks.refuseNext = ShareLinkFailure.slugTaken
        await fake.copy()
        expect(fake.failure != nil && !fake.copied && fake.link == nil,
               "replacement failure: a revoked token must not remain copyable")
        await fake.newLink()
        await fake.copy()
        expect(fake.failure == nil && fake.link?.slug == "retry-link" && fake.copied,
               "replacement failure: retry must produce a usable link")

        var samples: [Sample] = []

        // 1. The first share on this Mac (no host registered yet).
        let popoverA = try share(agentA)
        let cold = try await measure("cold-agent", popoverA)
        expectCopied(cold, link: popoverA.session.link)
        samples.append(cold)
        try capture("copied", popoverA)
        // 2. Copy again on the live link: nothing to wait for.
        try await Task.sleep(for: .milliseconds(250)) // settle trailing host traffic
        let again = try await measure("copy-again", popoverA)
        expect(again.accountRequests.isEmpty, "copy-again: Copy on a live link made \(again.requests.count) relay requests")
        expect((again.pasteboardMs ?? 1e9) < 50, "copy-again: the live link took \(again.pasteboardMs ?? -1) ms to reach the pasteboard")
        expectCopied(again, link: popoverA.session.link)
        samples.append(again)
        app.shareEntry.dismiss()

        let reopenedLocal = try share(agentA)
        try await Task.sleep(for: .milliseconds(250)) // opening refreshes the access list independently
        let local = try await measure("reopen-cached-link", reopenedLocal)
        expectCopied(local, link: reopenedLocal.session.link)
        expect(local.accountRequests.isEmpty && (local.pasteboardMs ?? 1e9) < 50,
               "reopen-cached-link: a valid retained link must copy locally")
        samples.append(local)
        app.shareEntry.dismiss()

        // 3. A second agent, everything warm. Double-pressed: one share only.
        let popoverB = try share(agentB)
        let areasBefore = proxy.requests.filter { $0.line.hasPrefix("POST /collaboration/v1/areas ") }.count
        let warm = try await measure("warm-agent-double-press", popoverB, extraClicks: 1)
        expectCopied(warm, link: popoverB.session.link)
        let areasMade = proxy.requests.filter { $0.line.hasPrefix("POST /collaboration/v1/areas ") }.count - areasBefore
        let linksMade = warm.requests.filter { $0.line.hasPrefix("POST ") && $0.line.contains("/links ") }.count
        expect(areasMade == 1 && linksMade == 1, "warm-agent-double-press: a double press made \(areasMade) areas and \(linksMade) links")
        expect(warm.requests.filter { $0.line.contains("/self ") }.count <= 4,
               "warm-agent: redundant identity round trips on the critical path")
        samples.append(warm)
        app.shareEntry.dismiss()

        // 4. The agent with the long transcript.
        let popoverD = try share(agentD)
        app.agentSupervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "busy"), to: bigAgent)
        let busy = Timer(timeInterval: 0.025, repeats: true) { _ in
            MainActor.assumeIsolated {
                app.agentSupervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "busy", streamKind: .assistant,
                    delta: "Checking current workspace state. "), to: bigAgent)
            }
        }
        RunLoop.main.add(busy, forMode: .common)
        let big = try await measure("big-busy-agent-\(bigEntries)-entries", popoverD)
        busy.invalidate()
        app.agentSupervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "busy", outcome: .completed, errorMessage: nil), to: bigAgent)
        expectCopied(big, link: popoverD.session.link)
        samples.append(big)
        app.shareEntry.dismiss()

        // 5. A live note.
        let popoverC = try share(noteC)
        let note = try await measure("live-note", popoverC)
        expectCopied(note, link: popoverC.session.link)
        samples.append(note)
        app.shareEntry.dismiss()

        // 6. After a relaunch the token is gone: New link on the shared area.
        app.qaInstallShareEntry(pasteboard: pasteboard)
        app.shareEntry.presentsOffscreenForQA = true
        let reopened = try share(agentB)
        expect({ if case .existing = reopened.session.phase { return true }; return false }(),
               "existing: a fresh popover on a shared agent opens as already shared (\(reopened.session.phase))")
        // The original one-use link remains active. A fresh token needs a
        // different slug; the relay correctly reserves the live one.
        reopened.session.setSlug("reopened-new-link")
        let existing = try await measure("existing-new-link", reopened)
        expectCopied(existing, link: reopened.session.link)
        let existingLinks = existing.requests.filter { $0.line.hasPrefix("POST ") && $0.line.contains("/links ") }.count
        expect(existingLinks == 1 && !existing.requests.contains { $0.line.hasPrefix("POST /collaboration/v1/areas ") },
               "existing-new-link: New link should only mint (made \(existing.requests.map(\.line)))")
        samples.append(existing)

        // 7. Revoke, then reshare with the link mint held: the press shows
        //    pending at once, the main thread keeps beating, nothing reaches the
        //    pasteboard and nothing says Copied until the relay answers.
        await reopened.session.revoke()
        expect(reopened.session.failure == nil && reopened.session.area == nil, "revoke before reshare failed (\(reopened.session.failure ?? ""))")
        proxy.hold { $0.hasPrefix("POST ") && $0.contains("/links ") }
        var heldPasteboard = true, heldCopied = false, heldPending = false
        let held = try await measure("reshare-held-mint", reopened, extraClicks: 1, whileWorking: { _ in
            let deadline = Date().addingTimeInterval(10)
            while proxy.held == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
            let change = pasteboard.changeCount
            try? await Task.sleep(for: .milliseconds(800))
            heldPasteboard = pasteboard.changeCount == change
            heldCopied = reopened.copyButton.presentation.title == "Copied"
            heldPending = reopened.copyButton.presentation.isLoading && !reopened.copyButton.presentation.isEnabled
            proxy.release()
        })
        proxy.release()
        expect(heldPasteboard && !heldCopied && heldPending,
               "reshare-held-mint: while the relay held the mint, pasteboard unchanged \(heldPasteboard), Copied \(heldCopied), pending \(heldPending)")
        expect(held.maxMainGapMs < 100, "reshare-held-mint: the main thread stalled \(Int(held.maxMainGapMs)) ms while the relay was held")
        expectCopied(held, link: reopened.session.link)
        samples.append(held)
        app.shareEntry.dismiss()

        let manifest: [[String: Any]] = samples.map { s in
            ["label": s.label, "pendingMs": s.pendingMs ?? -1, "pendingTitle": s.pendingTitle, "pasteboardMs": s.pasteboardMs ?? -1,
             "copiedMs": s.copiedMs ?? -1, "doneMs": s.doneMs, "mainGapMaxMs": s.maxMainGapMs, "requestCount": s.requests.count,
             "requests": s.requests.map { ["line": $0.line, "ms": ($0.seconds ?? -1) * 1000] }]
        }
        let out = ProcessInfo.processInfo.environment["ARRAY_SHARE_LATENCY_OUT"].map { URL(fileURLWithPath: $0) }
        if let out {
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["roundTripMs": roundTrip * 1000, "bigEntries": bigEntries, "samples": manifest],
                                       options: [.prettyPrinted, .sortedKeys]).write(to: out)
        }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "\n")) }
        return "share copy latency: \(samples.count) presses, round trip \(Int(roundTrip * 1000)) ms"
    }
}
