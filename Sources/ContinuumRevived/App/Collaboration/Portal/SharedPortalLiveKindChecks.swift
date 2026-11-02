import AppKit
import WebKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// `--portal-kinds-check [dir]` (`PORTAL-CONTRACT.md`, `SHARE-KINDS.md`): the
/// note, file, diff and browser kinds through the portal contract. On a mounted
/// production canvas it drives each kind's real `snapshot` on a real tile and
/// its real `observe` after a real change, then hands each revision to the
/// kind's real guest view through `apply(contents:)` and reads its `qaFacts`.
/// The guest views are drawn in light and dark, off screen.
@MainActor
enum SharedPortalLiveKindChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(description: label) }
        print("PASS portal kinds: \(label)")
    }

    /// The newest draft an observation handed over.
    @MainActor final class DraftBox { var draft: SharedArtifactProducer.Draft? }

    static func run(directory: URL) async throws {
        let scene = try ShareEntryChecks.mountScene("portal-kinds")
        defer { scene.close() }
        let app = scene.app, canvas = scene.canvas
        guard let root = scene.fixture.projectRoots[WorkspaceInvariantsFixture.projectA1],
              let spawner = app.spawnerForFilesystemCreation() else { throw Failure(description: "no project to spawn into") }
        let readme = root.appendingPathComponent("README.md")
        try "# Portal\n\nfirst line\n".write(to: readme, atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "README.md"], ["-c", "user.name=Check", "-c", "user.email=check@example.invalid", "commit", "-q", "-m", "start"]] {
            guard DiffLiveSource.git(arguments, root: root) != nil else { throw Failure(description: "git \(arguments[0]) failed") }
        }
        try "# Portal\n\nfirst line\nchanged for the diff\n".write(to: readme, atomically: true, encoding: .utf8)

        guard case .spawned(_, let note) = spawner.spawnNote(title: "Portal note"),
              case .spawned(let file) = spawner.spawnFile(path: readme.path),
              case .spawned(let diff) = spawner.spawnDiffReview(sendCommentsToAgent: { _ in }),
              case .spawned(let browserRuntime) = spawner.spawnBrowser(url: "http://127.0.0.1:9/portal") else {
            throw Failure(description: "a tile did not spawn")
        }
        canvas.layoutSubtreeIfNeeded()
        guard let noteView = canvas.tileView(for: note) as? NoteTileNSView else { throw Failure(description: "no note view") }
        noteView.textView.insertText("Plan: wallets first", replacementRange: NSRange(location: 0, length: 0))
        // A page only this Mac can reach: the kind sends it as a still.
        browserRuntime.webView.loadHTMLString("<html><body style='background:#fff'><h1>Portal page</h1><button>Pay</button></body></html>",
                                              baseURL: URL(string: "http://127.0.0.1:9/portal"))
        for _ in 0..<100 where browserRuntime.webView.isLoading || browserRuntime.webView.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
        let browser = browserRuntime.tileId

        let host = SharedPortalHostContext(app: app, area: UUID())
        let me = Collaboration.Identity(person: .init(), device: UUID()), owner = Collaboration.Identity(person: .init(), device: UUID())
        let document = SharedArea.Document()
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(me, .editor), (owner, .owner)])
        let rigRoot = FileManager.default.temporaryDirectory.appendingPathComponent("array-portal-kinds-\(UUID())")
        defer { try? FileManager.default.removeItem(at: rigRoot) }
        let controller = try SharedAreaCheckRig.controller(root: rigRoot, identity: me, label: "Sam", authority: authority, seed: (document, .editor))
        let guest = SharedPortalGuestContext(controller: controller, hostName: "Dylan", hostColour: .systemPurple)
        var sequence: UInt64 = 0
        func contents(_ draft: SharedArtifactProducer.Draft, object: SharedArea.ID<SharedArea.Object>) throws -> CollaborationArtifactContents {
            sequence += 1
            let capture = try draft.capture(object: object, parent: nil)
            var bytes: [String: Data] = [:]
            for entry in capture.manifest.entries where entry.coverage == .included {
                if let digest = entry.blob, let data = capture.blobs[digest] { bytes[entry.path] = data }
            }
            let record = Collaboration.Artifact.Record(manifest: capture.manifest, sequence: sequence, publisher: owner.person,
                                                       host: .init(), publishedAt: Date(), contentDigest: draft.contentDigest)
            return .init(record: record, bytes: bytes)
        }

        var views: [SharedPortalLiveItemView] = []
        func show(_ itemKind: SharedPortal.ItemKind, tile id: UUID, title: String) async throws -> (SharedPortalLiveItemView, any SharedPortalKind, SharedArea.ID<SharedArea.Object>) {
            let kind = SharedPortalKinds.kind(for: itemKind)
            guard let record = host.tile(id) else { throw Failure(description: "\(itemKind) tile has no record") }
            try require(kind.shareRow(for: record).included, "\(itemKind): the popover lists it as going")
            guard let draft = try await kind.snapshot(tile: record, host: host) else { throw Failure(description: "\(itemKind) published no snapshot") }
            let object = SharedArea.ID<SharedArea.Object>()
            guard let view = kind.makeView(entry: .init(object: object, kind: itemKind, title: title), guest: guest) as? SharedPortalLiveItemView else {
                throw Failure(description: "\(itemKind) still draws the fallback card")
            }
            view.apply(contents: try contents(draft, object: object))
            views.append(view)
            return (view, kind, object)
        }
        func observed(_ kind: any SharedPortalKind, tile: UUID, object: SharedArea.ID<SharedArea.Object>, into view: SharedPortalLiveItemView,
                      until done: () -> Bool) async throws -> Bool {
            let latest = DraftBox()
            let observation = kind.observe(tile: tile, host: host) { latest.draft = $0 }
            defer { observation?.cancel() }
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(100))
                if let draft = latest.draft { view.apply(contents: try contents(draft, object: object)); latest.draft = nil }
                if done() { return true }
            }
            return false
        }

        let (noteItem, noteKind, noteObject) = try await show(.note, tile: note, title: "Portal note")
        try require(noteItem.qaFacts["text"] == "Plan: wallets first" && noteItem.qaFacts["editable"] == "false",
                    "note: the guest shows the host's text, read only in the portal")
        noteView.textView.insertText(" · then Apple Pay", replacementRange: NSRange(location: (noteView.textView.string as NSString).length, length: 0))
        try require(try await observed(noteKind, tile: note, object: noteObject, into: noteItem) { noteItem.qaFacts["text"] == "Plan: wallets first · then Apple Pay" },
                    "note: a host edit reaches the portal through observe")
        // A rewrite, not an append: each revision replaces the text whole.
        noteView.textView.string = "Rewritten on the host"
        noteView.textView.didChangeText()
        try require(try await observed(noteKind, tile: note, object: noteObject, into: noteItem) { noteItem.qaFacts["text"] == "Rewritten on the host" },
                    "note: a whole rewrite on the host shows exactly in the portal: \(noteItem.qaFacts["text"] ?? "")")

        let (fileItem, fileKind, fileObject) = try await show(.file, tile: file, title: "README.md")
        try require(fileItem.qaFacts["text"]?.contains("changed for the diff") == true, "file: the guest shows the saved file (a real git capture)")
        try "# Portal\n\nfirst line\nchanged for the diff\nsaved again\n".write(to: readme, atomically: true, encoding: .utf8)
        try require(try await observed(fileKind, tile: file, object: fileObject, into: fileItem) { fileItem.qaFacts["text"]?.contains("saved again") == true },
                    "file: a save on the host reaches the portal as a new revision")

        let (diffItem, _, _) = try await show(.diff, tile: diff, title: "Changes")
        try require(diffItem.qaFacts["text"]?.contains("saved again") == true && diffItem.qaFacts["revision"] != "0",
                    "diff: the guest shows the host's working-tree diff")
        try require(diffItem.hoverActions.map(\.title) == ["Approve", "Request changes"], "diff: hovering offers Approve and Request changes")

        let (browserItem, _, _) = try await show(.browser, tile: browser, title: "Portal page")
        try require(browserItem.qaFacts["mode"] == "still" && browserItem.qaFacts["badge"] == "Still"
                    && browserItem.body.qaFrameSequence > 0 && browserItem.qaFacts["url"]?.contains("127.0.0.1") == true,
                    "browser (localhost): the guest shows a still marked Still: \(browserItem.qaFacts)")
        // The guest sees a browser tile, not a card: the host's title, its
        // address bar and page icon, and a state that says it is a still.
        try require(browserItem.qaFacts["chrome"] == "browser" && browserItem.qaFacts["address"] == "http://127.0.0.1:9/portal"
                    && browserItem.qaFacts["pageTitle"] == "Portal page" && browserItem.qaFacts["status"]?.contains("Still") == true,
                    "browser: the guest draws the host's browser chrome (title, address, status): \(browserItem.qaFacts)")

        // A URL that carries a sign-in or a secret: nothing of it leaves the
        // Mac but where the page is, and the guest gets a still, not the link.
        browserRuntime.webView.loadHTMLString("<html><head><title>Reset</title></head><body><h1>Reset</h1></body></html>",
                                              baseURL: URL(string: "https://sam:hunter2@shop.example.com/reset?token=abc123&lang=en#step=2"))
        for _ in 0..<100 where browserRuntime.webView.isLoading || browserRuntime.webView.url?.host != "shop.example.com" {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let secretRecord = host.tile(browser),
              let secretDraft = try await SharedPortalKinds.kind(for: .browser).snapshot(tile: secretRecord, host: host) else {
            throw Failure(description: "browser published nothing for a page with a secret in its URL")
        }
        let secretObject = SharedArea.ID<SharedArea.Object>()
        let sent = try contents(secretDraft, object: secretObject)
        let sentText = sent.bytes.values.compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n")
        let sentPayload = SharedPortal.decode(SharedPortal.BrowserPayload.self, name: SharedPortal.BrowserPayload.name, from: sent.bytes)
        try require(sentPayload?.url == "https://shop.example.com/reset" && sentPayload?.mode == .still
                    && !sentText.contains("abc123") && !sentText.contains("hunter2") && !sentText.contains("sam:"),
                    "browser: a URL's sign-in, token query and fragment never leave the host; it goes as a still: \(sentPayload.map { "\($0.url ?? "nil") \($0.mode)" } ?? "nil")")
        try require(Collaboration.LiveTile.shareable("https://duckduckgo.com/?q=swift+keyword&author=me").reach == .public
                    && Collaboration.LiveTile.shareable("https://duckduckgo.com/?q=swift+keyword&author=me").url == "https://duckduckgo.com/?q=swift+keyword&author=me"
                    && Collaboration.LiveTile.shareable("https://app.example.com/cb#access_token=x").reach == .private
                    && Collaboration.LiveTile.shareable("https://s3.example.com/f?X-Amz-Signature=1").reach == .private,
                    "browser: an ordinary query stays public and loads live; token fragments and signed URLs go as stills")

        // A public page: the guest's own browser loads it, in a store of its
        // own (no cookies of the guest's either), and after the guest clicks
        // away it offers the way back to the host's page.
        guard let publicDraft = SharedPortalBrowserKind.draft(.browser(.init(url: "https://example.com/docs?q=swift", title: "Docs", reach: .public, frame: nil)), still: nil),
              let publicItem = SharedPortalKinds.kind(for: .browser).makeView(entry: .init(object: .init(), kind: .browser, title: "Docs"), guest: guest) as? SharedPortalLiveItemView else {
            throw Failure(description: "no public browser item")
        }
        publicItem.frame = NSRect(x: 0, y: 0, width: 440, height: 460)
        publicItem.apply(contents: try contents(publicDraft, object: publicItem.entry.object))
        try require(publicItem.qaFacts["mode"] == "live" && publicItem.qaFacts["url"] == "https://example.com/docs?q=swift"
                    && publicItem.qaFacts["store"] == "ephemeral" && publicItem.qaFacts["address"] == "https://example.com/docs?q=swift"
                    && publicItem.qaFacts["status"] == "Following Dylan",
                    "browser (public): the guest loads the page itself, in an ephemeral store, following the host: \(publicItem.qaFacts)")
        guard let guestWeb = publicItem.body.qaWebView else { throw Failure(description: "the public page has no web view on the guest") }
        guestWeb.loadHTMLString("<html><body>elsewhere</body></html>", baseURL: URL(string: "https://example.org/elsewhere"))
        for _ in 0..<100 where publicItem.qaFacts["wandered"] != "true" { try await Task.sleep(for: .milliseconds(50)) }
        try require(publicItem.qaFacts["wandered"] == "true" && publicItem.body.qaBackToHost?.isHidden == false
                    && publicItem.qaFacts["status"] == "Your page",
                    "browser (public): a click away on the guest offers Back to Dylan's page: \(publicItem.qaFacts)")
        publicItem.body.qaBackToHost?.performClick(nil)
        try require(publicItem.qaFacts["wandered"] == "false" && publicItem.body.qaBackToHost?.isHidden == true
                    && publicItem.qaFacts["status"] == "Following Dylan",
                    "browser (public): Back to Dylan's page returns to following the host")
        views.append(publicItem)

        let terminal = SharedPortalKinds.kind(for: .terminal)
        try require(terminal.publishedTitle(for: Tile(id: UUID(), kind: .terminal, title: "secret-host:~", frame: .init(x: 0, y: 0, width: 10, height: 10),
                                                      zPosition: .fromLegacyRank(0), runtimeRef: nil, metadata: .init())) == "Terminal",
                    "terminal: a portal sends no terminal title or output")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let size = NSSize(width: CGFloat(views.count) * 460 + 20, height: 500)
            let board = NSView(frame: NSRect(origin: .zero, size: size))
            for (index, view) in views.enumerated() {
                view.removeFromSuperview()
                view.frame = NSRect(x: 20 + CGFloat(index) * 460, y: 20, width: 440, height: 460)
                board.addSubview(view)
            }
            let window = NSWindow(contentRect: board.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = board
            window.orderFrontOffscreenForChecks()
            board.layoutSubtreeIfNeeded(); board.displayIfNeeded()
            guard let rep = board.bitmapImageRepForCachingDisplay(in: board.bounds) else { throw Failure(description: "no bitmap") }
            board.cacheDisplay(in: board.bounds, to: rep)
            let name = "portal-kinds-\(appearance == .aqua ? "light" : "dark").png"
            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            print("WROTE \(directory.appendingPathComponent(name).path)")
            window.orderOut(nil)
        }
        print("PASS portal kinds: notes, files, diffs and browsers go through the portal contract and draw in light and dark")
    }
}
