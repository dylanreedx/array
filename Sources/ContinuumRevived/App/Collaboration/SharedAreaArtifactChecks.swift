import AppKit
import CryptoKit
import Foundation
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// COL-16 native journey. The owner chooses diff and file tiles in the real
/// capture review; the production producer reads a fixture checkout; the
/// confirmed publication uploads exact bytes; the recipient's production
/// scene renders the revision read-only, keeps the pinned revision apart from
/// the live latest, and its own checkout never changes. The authority is
/// scripted (the app links no service); the real routes are witnessed by the
/// service and Core legs.
@MainActor
enum SharedAreaArtifactChecks {
    struct Failure: Error { let message: String }
    typealias Artifact = Collaboration.Artifact
    private static func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw Failure(message: label) }
        print("PASS collaboration artifacts: \(label)")
    }
    private static func eventually(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw Failure(message: "timeout: \(label)")
    }

    static func run(mount: SharedAreaSceneChecks.Mount, executorCount: @MainActor () -> Int = { 0 }) async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else { throw Failure(message: "isolated app support required") }
        let root = URL(fileURLWithPath: support).appendingPathComponent("artifact-journey-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = root.appendingPathComponent("owner"), recipient = root.appendingPathComponent("recipient")
        for repo in [owner, recipient] { try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true); try git(repo, "init", "-q") }
        try write(owner, "src/feature.swift", "let value = 1\n")
        try git(owner, "add", "-A"); try git(owner, "commit", "-q", "-m", "base")
        try write(owner, "src/feature.swift", "let value = 2 // artifact-r1-sentinel\n")
        try write(owner, "scratch.txt", "untracked-private-sentinel\n")
        try write(recipient, "src/feature.swift", "recipient's own uncommitted work\n")
        let recipientBefore = try tree(recipient)
        let executorsBefore = executorCount()

        let a = Collaboration.Identity(person: .init(), device: UUID()), b = Collaboration.Identity(person: .init(), device: UUID())
        let host = SharedArea.ID<SharedArea.Host>()
        let authority = Authority(owner: a, member: b)
        let modelA = try controller(root: root.appendingPathComponent("a"), identity: a, authority: authority)
        let modelB = try controller(root: root.appendingPathComponent("b"), identity: b, authority: authority)
        await modelA.open(); await modelB.open()
        try expect(modelA.status == .connected && modelB.status == .connected && modelA.artifactTransport != nil,
                   "both people connect and the owner's controller exposes the artifact transport")

        // 1. Capture review: diff and file tiles become explicit snapshot choices.
        let project = UUID(), zone = UUID(), workspace = UUID()
        func tile(_ kind: TileKind, _ title: String, x: Double, _ metadata: TileMetadata) -> Tile {
            .init(id: UUID(), kind: kind, title: title, frame: .init(x: x, y: 0, width: 400, height: 300),
                  zPosition: .fromLegacyRank(1), zoneId: zone, runtimeRef: nil, metadata: metadata)
        }
        let diffTile = tile(.diffReview, "Working diff", x: 0, TileMetadata(diffSource: "workingTreeVsHEAD"))
        let fileTile = tile(.file, "Feature file", x: 450, TileMetadata(filePath: owner.appendingPathComponent("src/feature.swift").path))
        func snapshot() -> SharedAreaInventory.Snapshot {
            let sources = [diffTile, fileTile].map { SharedAreaPublication.SourceTile(projectID: project, tile: $0) }
            var value = SharedAreaInventory.Snapshot(inventory: .init(workspaceID: workspace, coverage: .completeWorkspace, sources: sources),
                                                     noteTexts: [:], issues: [])
            for source in sources { value.artifactSources[source.key] = SharedArtifactSource.resolve(tile: source.tile, projectRoot: owner) }
            return value
        }
        let coordinator = try SharedAreaCaptureCoordinator(selection: .workspace, controller: modelA, person: a.person, host: host,
            inventoryProvider: { snapshot() }, submitter: { await modelA.submitPublication($0) })
        let review = SharedAreaCaptureView(coordinator: coordinator)
        review.frame = .init(x: 0, y: 0, width: 780, height: 800); review.layoutSubtreeIfNeeded()
        try expect(!coordinator.canConfirm && coordinator.review.rows.allSatisfy { $0.disposition == .needsReview },
                   "opening review opts no diff or file tile in")
        for title in ["Working diff", "Feature file"] {
            guard let source = review.sourceChoice.items.first(where: { $0.title.contains(title) }) else { throw Failure(message: "missing row \(title)") }
            review.sourceChoice.handleSelection(source)
            guard let snapshotMode = review.modeChoice.items.first(where: { $0.id == "artifact" && $0.enabled }) else { throw Failure(message: "no snapshot mode for \(title)") }
            review.modeChoice.handleSelection(snapshotMode)
            await coordinator.captureTask?.value
        }
        try expect(coordinator.canConfirm && coordinator.review.rows.allSatisfy { $0.disposition == .ready(.artifact) },
                   "both tiles are captured off main into ready artifact rows")
        let diffKey = coordinator.review.rows.first { $0.tileKind == .diffReview }!.source
        let summary = coordinator.artifactSummary(diffKey) ?? ""
        try expect(summary.contains("src/feature.swift") && summary.contains("1 untracked files are not included") && !summary.contains("scratch.txt"),
                   "review shows the included path and counts the untracked file without naming it")

        // 2. Bytes changed after review refuse; nothing is sent.
        try write(owner, "src/feature.swift", "let value = 3 // changed-after-review\n")
        await coordinator.confirm()
        try expect(coordinator.requiresRefresh && coordinator.state == .reviewing, "an edit after review refuses confirmation")
        let appliedCount = await authority.applied, publishedCount = await authority.published.count
        try expect(appliedCount == 0 && publishedCount == 0, "the refused review sent no command and no bytes")
        try coordinator.refreshReview()
        await coordinator.captureTask?.value
        await coordinator.confirm()
        try expect(coordinator.state == .published && coordinator.publishedArtifacts == 2, "the refreshed review publishes both artifacts")
        let published = await authority.published
        let allBytes = published.flatMap { $0.blobs.values }.map { String(decoding: $0, as: UTF8.self) }.joined()
        try expect(allBytes.contains("changed-after-review") && !allBytes.contains("untracked-private-sentinel")
                   && published.allSatisfy { $0.manifest.parent == nil },
                   "uploaded revisions carry the confirmed bytes and never the unselected untracked file")
        let document = await authority.document
        let diffItem = document.items.first { item in published.contains { $0.manifest.object == item.id && $0.manifest.kind == .diff } }!
        try expect(diffItem.kind == .artifact && diffItem.source?.owner == a.person && diffItem.source?.host == host,
                   "the admitted artifact is sourced to the owner's host")

        // 3. The recipient's production scene renders it read-only.
        let hostView = NSView(frame: .init(x: 0, y: 0, width: 1200, height: 820))
        let scene = try mount(modelB, b.person, hostView)
        hostView.layoutSubtreeIfNeeded()
        try await eventually("recipient receives the document") { modelB.document?.items.contains { $0.id == diffItem.id } == true }
        try scene.selectObject(diffItem.id)
        let panel = scene.artifactPanel
        try await eventually("revision 1 renders") { panel.contents?.record.sequence == 1 && panel.renderedText.contains("changed-after-review") }
        try expect(!panel.isHidden && panel.summaryText == "Revision 1 · live latest" && panel.applicabilityText.hasPrefix("Current"),
                   "the recipient scene shows revision 1 as the current live latest")
        try expect(scene.subviews.contains(panel) && panel.frame.width > 200 && panel.frame.height > 200, "the artifact view takes the inspector reader's place")

        // 4. Approval pins to revision 1 and never moves to revision 2.
        let r1 = panel.contents!.record.manifest.id
        _ = try await authority.review(b, object: diffItem.id, revision: r1)
        try await eventually("approval appears") { panel.coverageText.contains("You approved this revision") }
        try write(owner, "src/feature.swift", "let value = 4 // artifact-r2-sentinel\n")
        let draft = try SharedArtifactSource.resolve(tile: diffTile, projectRoot: owner)!.draft()
        _ = try await modelA.artifactTransport!.publishArtifact(epoch: 1, capture: try draft.capture(object: diffItem.id, parent: r1))
        try await eventually("live wake moves the followed view to revision 2") { panel.contents?.record.sequence == 2 }
        try expect(panel.summaryText == "Revision 2 · live latest" && panel.renderedText.contains("artifact-r2-sentinel")
                   && panel.coverageText.contains("1 review on another revision does not apply here") && !panel.coverageText.contains("You approved"),
                   "the new latest shows no approval; the revision 1 approval is reported as not applying")
        panel.showRevision(r1)
        try await eventually("pinned revision 1") { panel.contents?.record.sequence == 1 }
        try expect(panel.summaryText == "Revision 1 · pinned for review · latest is revision 2"
                   && panel.applicabilityText.hasPrefix("Superseded by revision 2") && panel.coverageText.contains("You approved this revision (superseded)")
                   && panel.renderedText.contains("changed-after-review"),
                   "the revision under review stays distinct from the live latest, with its approval marked superseded")
        panel.showRevision(nil)
        try await eventually("back to latest") { panel.contents?.record.sequence == 2 }
        try await authority.drift(object: diffItem.id, revision: panel.contents!.record.manifest.id)
        try await eventually("drift reaches the recipient") { panel.applicabilityText.hasPrefix("Source changed") }
        try expect(panel.applicabilityText == "Source changed on the owner's Mac · not applicable",
                   "a source change shows not applicable instead of current")

        // 5. Light and dark render through the same token renderer.
        for (name, theme) in [(NSAppearance.Name.aqua, TokenTheme.light), (.darkAqua, .dark)] {
            panel.appearance = NSAppearance(named: name)
            panel.viewDidChangeEffectiveAppearance()
            let storage = panel.renderedStorage ?? NSAttributedString()
            var additionColor: NSColor?
            storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if (storage.string as NSString).substring(with: range).hasPrefix("+let value") { additionColor = value as? NSColor; stop.pointee = true }
            }
            try expect(same(additionColor, AccentToken.accentDone.color.nsColor(for: theme)) && same(panel.textBackground, SurfaceToken.tileBody.color.nsColor(for: theme)),
                       "\(theme) appearance renders added lines and the body in that theme's tokens")
            if let evidence = ProcessInfo.processInfo.environment["CONTINUUM_ARTIFACT_EVIDENCE_DIR"],
               let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                // The panel draws on the scene's panel surface; paint it first
                // so the evidence shows what a person sees in that theme.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor.clear.set(); NSRect(origin: .zero, size: rep.size).fill(using: .copy)
                NSGraphicsContext.restoreGraphicsState()
                panel.cacheDisplay(in: panel.bounds, to: rep)
                let image = NSImage(size: panel.bounds.size)
                image.lockFocus()
                SurfaceToken.panel.color.nsColor(for: theme).setFill(); NSRect(origin: .zero, size: panel.bounds.size).fill()
                rep.draw(in: NSRect(origin: .zero, size: panel.bounds.size))
                image.unlockFocus()
                if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: evidence).appendingPathComponent("artifact-\(theme).png"))
                }
            }
        }
        try expect(try tree(recipient) == recipientBefore, "the recipient's checkout is byte-identical after reading every revision")
        try expect(executorCount() == executorsBefore, "reading artifacts constructs no executor")
        scene.unmount()
        await modelA.close(); await modelB.close()
    }

    // MARK: - Fixture

    private static func same(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.002 && abs(a.greenComponent - b.greenComponent) < 0.002
            && abs(a.blueComponent - b.blueComponent) < 0.002 && abs(a.alphaComponent - b.alphaComponent) < 0.002
    }
    /// An accepted share whose uploads failed must still publish exactly the
    /// confirmed bytes, under the reserved revision IDs, after a relaunch and on
    /// reconnect — and never send a revision that already landed.
    static func runUploadRecovery() async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else { throw Failure(message: "isolated app support required") }
        let root = URL(fileURLWithPath: support).appendingPathComponent("artifact-upload-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = root.appendingPathComponent("owner")
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true); try git(owner, "init", "-q")
        try write(owner, "src/feature.swift", "let value = 1\n")
        try git(owner, "add", "-A"); try git(owner, "commit", "-q", "-m", "base")
        try write(owner, "src/feature.swift", "let value = 2 // confirmed-upload-sentinel\n")

        let a = Collaboration.Identity(person: .init(), device: UUID()), b = Collaboration.Identity(person: .init(), device: UUID())
        let authority = Authority(owner: a, member: b)
        let cache = root.appendingPathComponent("a")
        var model = try controller(root: cache, identity: a, authority: authority)
        await model.open()
        let project = UUID(), zone = UUID(), workspace = UUID()
        let tiles = [Tile(id: UUID(), kind: .diffReview, title: "Working diff", frame: .init(x: 0, y: 0, width: 400, height: 300),
                          zPosition: .fromLegacyRank(1), zoneId: zone, runtimeRef: nil, metadata: TileMetadata(diffSource: "workingTreeVsHEAD")),
                     Tile(id: UUID(), kind: .file, title: "Feature file", frame: .init(x: 450, y: 0, width: 400, height: 300),
                          zPosition: .fromLegacyRank(1), zoneId: zone, runtimeRef: nil,
                          metadata: TileMetadata(filePath: owner.appendingPathComponent("src/feature.swift").path))]
        func snapshot() -> SharedAreaInventory.Snapshot {
            let sources = tiles.map { SharedAreaPublication.SourceTile(projectID: project, tile: $0) }
            var value = SharedAreaInventory.Snapshot(inventory: .init(workspaceID: workspace, coverage: .completeWorkspace, sources: sources),
                                                     noteTexts: [:], issues: [])
            for source in sources { value.artifactSources[source.key] = SharedArtifactSource.resolve(tile: source.tile, projectRoot: owner) }
            return value
        }
        let sharing = model
        let coordinator = try SharedAreaCaptureCoordinator(selection: .workspace, controller: sharing, person: a.person, host: .init(),
            inventoryProvider: { snapshot() }, submitter: { await sharing.submitPublication($0) })
        for row in coordinator.review.rows {
            try coordinator.setMode(.artifact, for: row.source)
            await coordinator.captureTask?.value
        }
        // One upload never reaches the service; the other commits but its reply is lost.
        await authority.script([.refuse, .loseReply])
        await coordinator.confirm()
        let objects = Set(await authority.document.items.filter { $0.kind == .artifact }.map(\.id))
        let firstAttempts = await authority.attempts, firstRevisions = await authority.revisionCount
        try expect(coordinator.state == .published && coordinator.publishedArtifacts == 0 && objects.count == 2
                   && firstAttempts.count == 2 && firstRevisions == 1,
                   "the arrangement is accepted while one upload fails and one reply is lost")
        try expect(coordinator.message.contains("could not be uploaded yet") && coordinator.message.contains("relaunches"),
                   "the owner is told the snapshots upload later instead of being lost")
        // Edits after sharing must not reach the retry: it sends the confirmed capture.
        try write(owner, "src/feature.swift", "let value = 3 // edited-after-share\n")

        // Relaunch: a new controller over the same local cache, the service still failing.
        await model.close()
        await authority.script([.refuse])
        model = try controller(root: cache, identity: a, authority: authority)
        await model.open()
        let uploads = model.localAreaDirectory.appendingPathComponent("uploads")
        func staged() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: uploads.path)) ?? []).filter { $0.hasSuffix(".json") }.count }
        try await eventually("relaunch retries the upload that never landed") { staged() == 1 }
        try await Task.sleep(for: .milliseconds(200))
        let relaunchAttempts = await authority.attempts.count, relaunchRevisions = await authority.revisionCount
        try expect(relaunchAttempts == 3 && relaunchRevisions == 1,
                   "relaunch retries the missing snapshot once and never resends the one whose reply was lost")

        // Reconnect with the service healthy: the remaining snapshot lands.
        await authority.reconnect(a)
        try await eventually("reconnect uploads the remaining snapshot") { staged() == 0 }
        let attempts = await authority.attempts, revisions = await authority.records
        try expect(attempts.count == 4 && objects.allSatisfy { revisions[$0]?.count == 1 },
                   "reconnect publishes the remaining snapshot; each artifact has exactly one revision")
        let reserved = Dictionary(firstAttempts.map { ($0.manifest.object, $0.manifest.id) }, uniquingKeysWith: { first, _ in first })
        let landed = attempts.filter { attempt in revisions[attempt.manifest.object]?.first?.manifest.id == attempt.manifest.id }
        let bytes = landed.flatMap { $0.blobs.values }.map { String(decoding: $0, as: UTF8.self) }.joined()
        try expect(objects.allSatisfy { revisions[$0]?.first?.manifest.id == reserved[$0] }
                   && bytes.contains("confirmed-upload-sentinel") && !bytes.contains("edited-after-share"),
                   "every revision carries the ID reserved at review and the confirmed bytes, not a new capture")

        // A second relaunch has nothing left to send.
        await model.close()
        model = try controller(root: cache, identity: a, authority: authority)
        await model.open()
        try await Task.sleep(for: .milliseconds(300))
        let finalAttempts = await authority.attempts.count, finalRevisions = await authority.revisionCount
        try expect(model.status == .connected && finalAttempts == 4 && finalRevisions == 2,
                   "a later relaunch sends nothing again")
        await model.close()
    }


    private static func git(_ repo: URL, _ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"] + args
        process.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = env
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: "fixture git \(args.joined(separator: " "))") }
    }
    private static func write(_ repo: URL, _ path: String, _ text: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private static func tree(_ repo: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let walker = FileManager.default.enumerator(at: repo, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in walker where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            result[url.path] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
    private static func controller(root: URL, identity: Collaboration.Identity, authority: Authority) throws -> SharedAreaController {
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://shared-artifacts.example.test")!)
        let credentials = CollaborationCredentialStore(vault: MemoryVault(), bundleIdentifier: nil)
        let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
        try credentials.save(.init(identity: identity, token: "scripted-artifacts-only"), for: scope)
        let cache = try SharedAreaLocalStore(applicationSupportRoot: root, bundleIdentifier: nil, endpoint: endpoint,
                                             person: identity.person, area: authority.area)
        if try cache.load() == nil { try cache.save(.init(scope: cache.scope, document: .init(id: authority.area), observedMembershipEpoch: 1)) }
        return try SharedAreaController(localStore: cache, credentialStore: credentials, credentialScope: scope,
            bundleIdentifier: nil, transportFactory: { _, _, _ in Transport(identityValue: identity, authority: authority) })
    }
    private final class MemoryVault: CollaborationCredentialVault, @unchecked Sendable {
        let lock = NSLock(); var values: [String: Data] = [:]
        func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
        func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
        func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
    }
    private actor Connection: SharedAreaControllerConnection {
        let pair = AsyncStream<CollaborationSession.Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        func start() async -> AsyncStream<CollaborationSession.Status> { pair.stream }
        func stop() async { pair.continuation.finish() }
        func emit(_ value: CollaborationSession.Status) { pair.continuation.yield(value) }
    }
    /// Scripted authority with the service's artifact semantics: verified
    /// bytes, parent CAS, pinned reviews and set-once drift.
    private actor Authority {
        nonisolated let area = SharedArea.ID<SharedArea.Area>()
        let owner: Collaboration.Identity, member: Collaboration.Identity
        var document: SharedArea.Document
        var applied = 0
        var published: [Artifact.Capture] = []
        var records: [SharedArea.ID<SharedArea.Object>: [Artifact.Record]] = [:]
        var blobs: [String: Data] = [:]
        var reviews: [Artifact.Review] = []
        var connections: [UUID: (Collaboration.Identity, Connection)] = [:]
        init(owner: Collaboration.Identity, member: Collaboration.Identity) {
            self.owner = owner; self.member = member; document = .init(id: area)
        }
        func state(_ identity: Collaboration.Identity) -> Collaboration.State {
            .init(scope: .init(area: area, epoch: 1, role: identity == owner ? .owner : .editor), document: document)
        }
        func connection(_ identity: Collaboration.Identity) -> Connection {
            let connection = Connection(); connections[identity.device] = (identity, connection); return connection
        }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt {
            applied += 1
            let result = try document.apply(mutation.command)
            await broadcast()
            switch result { case .applied(let r): return .init(revision: r, duplicate: false); case .duplicate(let r): return .init(revision: r, duplicate: true) }
        enum PublishOutcome { case refuse, loseReply }
        /// Outcomes for the next publish calls; an empty script commits.
        private var publishScript: [PublishOutcome] = []
        /// Every publish call, including refused ones.
        var attempts: [Artifact.Capture] = []
        var revisionCount: Int { records.values.reduce(0) { $0 + $1.count } }
        func script(_ outcomes: [PublishOutcome]) { publishScript = outcomes }
        func reconnect(_ identity: Collaboration.Identity) async {
            await connections[identity.device]?.1.emit(.reconnecting(nil))
            await broadcast()
        }
        }
        func publish(_ capture: Artifact.Capture, by identity: Collaboration.Identity) async throws -> Artifact.PublishReceipt {
            let m = capture.manifest
            guard let item = document.items.first(where: { $0.id == m.object && $0.kind == .artifact }), item.source?.owner == identity.person else {
                throw CollaborationClientError.server(status: 403, code: "forbidden")
            }
            try Artifact.validate(m)
            guard records[m.object]?.last?.manifest.id == m.parent else { throw CollaborationClientError.server(status: 409, code: "revisionConflict") }
            for entry in m.entries where entry.coverage == .included { try Artifact.verify(capture.blobs[entry.blob!] ?? Data(), for: entry); blobs[entry.blob!] = capture.blobs[entry.blob!] }
            let sequence = UInt64((records[m.object]?.count ?? 0) + 1)
            records[m.object, default: []].append(.init(manifest: m, sequence: sequence, publisher: identity.person, host: item.source!.host,
                                                        publishedAt: Date(), contentDigest: m.contentDigest))
            published.append(capture)
            await broadcast()
            return .init(revision: m.id, sequence: sequence, duplicate: false)
        }
        func review(_ identity: Collaboration.Identity, object: SharedArea.ID<SharedArea.Object>, revision: SharedArea.ID<Artifact.RevisionTag>) async throws -> Artifact.Review {
            attempts.append(capture)
            let outcome = publishScript.isEmpty ? nil : publishScript.removeFirst()
            if outcome == .refuse { throw CollaborationClientError.server(status: 503, code: "unavailable") }
            // The service's idempotency: a known revision ID is a duplicate.
            if let record = records[m.object]?.first(where: { $0.manifest.id == m.id }), record.contentDigest == m.contentDigest {
                return .init(revision: m.id, sequence: record.sequence, duplicate: true)
            }
            guard let record = records[object]?.first(where: { $0.manifest.id == revision }) else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            let value = Artifact.Review(id: .init(), object: object, revision: revision, contentDigest: record.contentDigest,
                                        author: identity.person, verdict: .approve, note: "", createdAt: Date())
            reviews.append(value); await broadcast(); return value
        }
        func drift(object: SharedArea.ID<SharedArea.Object>, revision: SharedArea.ID<Artifact.RevisionTag>) async throws {
            guard let index = records[object]?.firstIndex(where: { $0.manifest.id == revision }) else { throw Failure(message: "no revision") }
            if records[object]![index].drift == nil { records[object]![index].drift = .init(changedPaths: 1, baseMoved: false, observedAt: Date()) }
            await broadcast()
        }
        func artifactState(_ object: SharedArea.ID<SharedArea.Object>) throws -> Artifact.State {
            if outcome == .loseReply { throw URLError(.networkConnectionLost) }
            guard document.items.contains(where: { $0.id == object && $0.kind == .artifact }) else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            let list = records[object] ?? []
            func applicability(_ id: SharedArea.ID<Artifact.RevisionTag>) -> Artifact.Applicability {
                guard let latest = list.last, let record = list.first(where: { $0.manifest.id == id }) else { return .current }
                if id != latest.manifest.id { return .superseded(by: latest.manifest.id) }
                return record.drift.map { .sourceChanged($0) } ?? .current
            }
            return .init(object: object, latest: list.last,
                revisions: list.map { .init(id: $0.manifest.id, sequence: $0.sequence, contentDigest: $0.contentDigest, applicability: applicability($0.manifest.id)) },
                reviews: reviews.filter { $0.object == object }.map { .init(review: $0, applicability: applicability($0.revision)) })
        }
        func read(_ object: SharedArea.ID<SharedArea.Object>, revision: UUID?) throws -> CollaborationArtifactContents {
            let list = records[object] ?? []
            guard let record = revision.map({ id in list.first { $0.manifest.id.rawValue == id } }) ?? list.last else {
                throw CollaborationClientError.server(status: 404, code: "notFound")
            }
            var bytes: [String: Data] = [:]
            for entry in record.manifest.entries where entry.coverage == .included {
                let data = blobs[entry.blob!] ?? Data(); try Artifact.verify(data, for: entry); bytes[entry.path] = data
            }
            return .init(record: record, bytes: bytes)
        }
        private func heads() -> [Artifact.Head] {
            records.compactMap { object, list in
                list.last.map { .init(object: object, revision: $0.manifest.id, sequence: $0.sequence, sourceChanged: $0.drift != nil,
                                      reviews: reviews.filter { $0.object == object }.count) }
            }
        }
        /// Each connection receives the document plus current artifact heads,
        /// exactly as an updates page would deliver them.
        private func broadcast() async {
            for (identity, connection) in connections.values {
                guard var replica = try? CollaborationReplica(state: .init(scope: state(identity).scope, document: document)) else { continue }
                try? replica.receive(.init(scope: state(identity).scope, after: document.revision, through: document.revision, events: [],
                    nextCursor: document.revision, presenceVersion: UUID(), presence: [], serverTime: Date(), artifactHeads: heads()))
                await connection.emit(.connected(replica))
            }
        }
    }
    private struct Transport: SharedAreaControllerTransport, SharedAreaArtifactTransport {
        let identityValue: Collaboration.Identity
        let authority: Authority
        func identity() async throws -> Collaboration.Identity { identityValue }
        func state() async throws -> Collaboration.State { await authority.state(identityValue) }
        func connection(initial: Collaboration.State) async throws -> any SharedAreaControllerConnection { await authority.connection(identityValue) }
        func apply(_ mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt { try await authority.apply(mutation) }
        func artifactState(object: UUID) async throws -> Artifact.State { try await authority.artifactState(.init(object)) }
        func readArtifact(object: UUID, revision: UUID?) async throws -> CollaborationArtifactContents { try await authority.read(.init(object), revision: revision) }
        func publishArtifact(epoch: Int64, capture: Artifact.Capture) async throws -> Artifact.PublishReceipt { try await authority.publish(capture, by: identityValue) }
        func reviewArtifact(object: UUID, request: Artifact.ReviewRequest) async throws -> Artifact.Review {
            try await authority.review(identityValue, object: .init(object), revision: request.revision)
        }
    }
}
