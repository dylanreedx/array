import AppKit
import WebKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

// Notes, files, diffs and browsers inside a portal
// (`.plans/105-collaboration/PORTAL-CONTRACT.md`, `SHARE-KINDS.md`). Each is an
// artifact item whose revisions carry the contract's standard payloads; the
// guest draws them with the same `LiveTileBodyView` a tile shared on its own
// uses, read only, as the portal contract asks. Editing a note together and
// clicking a private page are what a tile shared on its own adds.

/// Watches one tile on the host and hands the portal a draft on a beat; the
/// portal drops a draft equal to the last one sent.
@MainActor
final class SharedPortalPollObservation: SharedPortalObservation {
    private var task: Task<Void, Never>?
    init(every interval: Duration, draft: @escaping @MainActor () async -> SharedArtifactProducer.Draft?,
         publish: @escaping @MainActor (SharedArtifactProducer.Draft) -> Void) {
        task = Task { @MainActor in
            while !Task.isCancelled {
                if let next = await draft() { publish(next) }
                try? await Task.sleep(for: interval)
            }
        }
    }
    func cancel() { task?.cancel(); task = nil }
}

@MainActor
struct SharedPortalNoteKind: SharedPortalKind {
    var itemKind: SharedPortal.ItemKind { .note }
    func shareRow(for tile: Tile) -> SharedPortalShareRow { .init(included: true, badge: "Live") }

    static func text(tile id: UUID, host: SharedPortalHostContext) -> String? {
        guard let app = host.app, let tile = host.tile(id), let noteID = tile.metadata.noteId, let zone = tile.zoneId,
              let project = app.canvasView?.projectId(forZone: zone), let controller = app.sharedAreaRuntime?.controller(for: project) else { return nil }
        if let view = (host.tileView(id) as? NoteTileNSView) ?? controller.noteViews[noteID] { return view.textView.string }
        return try? controller.projectStore.loadNoteBody(id: noteID)
    }
    func snapshot(tile: Tile, host: SharedPortalHostContext) async throws -> SharedArtifactProducer.Draft? {
        guard let text = Self.text(tile: tile.id, host: host) else { return nil }
        return try SharedPortal.jsonDraft(SharedPortal.NotePayload(text: text), name: SharedPortal.NotePayload.name)
    }
    func observe(tile: UUID, host: SharedPortalHostContext,
                 publish: @escaping @MainActor (SharedArtifactProducer.Draft) -> Void) -> (any SharedPortalObservation)? {
        SharedPortalPollObservation(every: .milliseconds(500), draft: {
            guard let text = Self.text(tile: tile, host: host) else { return nil }
            return try? SharedPortal.jsonDraft(SharedPortal.NotePayload(text: text), name: SharedPortal.NotePayload.name)
        }, publish: publish)
    }
    func makeView(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) -> SharedPortalItemView {
        SharedPortalLiveItemView(entry: entry, guest: guest, kind: .note)
    }
}

/// A file or a diff: the real git capture, so the artifact reader and the
/// review route work on it unchanged.
@MainActor
struct SharedPortalCaptureKind: SharedPortalKind {
    let itemKind: SharedPortal.ItemKind
    func shareRow(for tile: Tile) -> SharedPortalShareRow { .init(included: true, badge: "Live") }

    static func source(tile id: UUID, host: SharedPortalHostContext) -> SharedArtifactSource? {
        guard let tile = host.tile(id), let root = host.projectRoot(forTile: id) else { return nil }
        return SharedArtifactSource.resolve(tile: tile, projectRoot: root)
    }
    static func draft(_ source: SharedArtifactSource) async -> SharedArtifactProducer.Draft? {
        await Task.detached { try? source.draft() }.value
    }
    func snapshot(tile: Tile, host: SharedPortalHostContext) async throws -> SharedArtifactProducer.Draft? {
        guard let source = Self.source(tile: tile.id, host: host) else { return nil }
        return await Self.draft(source)
    }
    func observe(tile: UUID, host: SharedPortalHostContext,
                 publish: @escaping @MainActor (SharedArtifactProducer.Draft) -> Void) -> (any SharedPortalObservation)? {
        SharedPortalPollObservation(every: itemKind == .diff ? .seconds(2) : .seconds(1), draft: {
            guard let source = Self.source(tile: tile, host: host) else { return nil }
            return await Self.draft(source)
        }, publish: publish)
    }
    func makeView(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) -> SharedPortalItemView {
        SharedPortalLiveItemView(entry: entry, guest: guest, kind: itemKind == .diff ? .diff : .file)
    }
}

/// A browser: a public page loads on the guest's Mac; anything private goes as
/// a still, re-sent only when the page changed and at most every 5 s.
@MainActor
struct SharedPortalBrowserKind: SharedPortalKind {
    var itemKind: SharedPortal.ItemKind { .browser }
    static let stillInterval: TimeInterval = 5

    func shareRow(for tile: Tile) -> SharedPortalShareRow {
        Collaboration.LiveTile.shareable(tile.metadata.url ?? "").reach == .private ? .init(included: true, badge: "Still")
            : .init(included: true, badge: "Live")
    }
    static func source(tile id: UUID, host: SharedPortalHostContext) -> BrowserLiveSource {
        let view: @MainActor () -> BrowserTileNSView? = { host.tileView(id) as? BrowserTileNSView }
        return BrowserLiveSource(webView: { (view()?.runtime as? WKWebViewBrowserRuntime)?.webView },
                                 address: { (view()?.runtime.url).flatMap { $0.isEmpty ? nil : $0 } ?? host.tile(id)?.metadata.url ?? "" },
                                 title: { view()?.runtime.title ?? host.tile(id)?.title ?? "" })
    }
    /// The contract's payload: `browser.json`, and for a private page the still.
    static func draft(_ payload: Collaboration.LiveTile.Payload?, still: Data?) -> SharedArtifactProducer.Draft? {
        guard case .browser(let browser)? = payload, let url = browser.url else { return nil }
        let mode: SharedPortal.BrowserPayload.Mode = browser.reach == .public ? .live : .still
        let extra = mode == .still ? still.map { [SharedPortal.BrowserPayload.stillEntry: $0.base64EncodedData()] } ?? [:] : [:]
        return try? SharedPortal.jsonDraft(SharedPortal.BrowserPayload(url: url, title: browser.title, mode: mode),
                                           name: SharedPortal.BrowserPayload.name, extra: extra)
    }
    func snapshot(tile: Tile, host: SharedPortalHostContext) async throws -> SharedArtifactProducer.Draft? {
        let payload = await Self.source(tile: tile.id, host: host).payload(eventsThrough: 0)
        guard case .browser(let browser)? = payload else { return nil }
        return Self.draft(payload, still: browser.frame?.jpeg)
    }
    func observe(tile: UUID, host: SharedPortalHostContext,
                 publish: @escaping @MainActor (SharedArtifactProducer.Draft) -> Void) -> (any SharedPortalObservation)? {
        let source = Self.source(tile: tile, host: host)
        var still: Data?, sentAt = Date.distantPast
        return SharedPortalPollObservation(every: .seconds(1), draft: {
            let payload = await source.payload(eventsThrough: 0)
            guard case .browser(let browser)? = payload else { return nil }
            // Each still costs its bytes again against the area's budget.
            if let frame = browser.frame?.jpeg, frame != still, Date().timeIntervalSince(sentAt) >= Self.stillInterval || still == nil {
                still = frame; sentAt = Date()
            }
            return Self.draft(payload, still: still)
        }, publish: publish)
    }
    func makeView(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) -> SharedPortalItemView {
        SharedPortalLiveItemView(entry: entry, guest: guest, kind: .browser)
    }
}

/// One note, file, diff or browser in the guest's portal: the same body a tile
/// shared on its own shows, read only, fed from the item's revisions.
@MainActor
final class SharedPortalLiveItemView: SharedPortalItemView {
    let body: LiveTileBodyView
    let liveKind: Collaboration.LiveTile.Kind
    private let generation = UUID()
    private var revision: UInt64 = 0
    private(set) var latest: CollaborationArtifactContents?
    private(set) var reviewed: String = ""

    init(entry: SharedPortal.Entry, guest: SharedPortalGuestContext, kind: Collaboration.LiveTile.Kind) {
        liveKind = kind
        body = LiveTileBodyView(kind: kind, hostName: guest.hostName)
        body.inputEnabled = false
        body.inPortal = true
        body.fallbackTitle = entry.title
        super.init(entry: entry, guest: guest)
        addSubview(body)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("\(entry.title), \(guest.hostName)'s \(LiveTileBodyView.noun(kind))")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func apply(contents: CollaborationArtifactContents?) {
        guard let contents, let payload = Self.payload(liveKind, title: entry.title, contents: contents) else { return }
        latest = contents
        revision += 1
        body.show(.init(generation: generation, revision: revision, payload: payload))
    }

    /// The contract's revisions, as the payload the body draws.
    static func payload(_ kind: Collaboration.LiveTile.Kind, title: String, contents: CollaborationArtifactContents) -> Collaboration.LiveTile.Payload? {
        let bytes = contents.bytes
        switch kind {
        case .note:
            guard let note = SharedPortal.decode(SharedPortal.NotePayload.self, name: SharedPortal.NotePayload.name, from: bytes) else { return nil }
            var replica = Collaboration.NoteText.Replica(replica: "portal")
            _ = replica.edit(to: note.text)
            return .note(.init(title: title, snapshot: replica.snapshot, eventsThrough: 0))
        case .file:
            guard let path = bytes.keys.sorted().first, let data = bytes[path] else { return nil }
            let text = String(data: data, encoding: .utf8)
            return .file(.init(name: (path as NSString).lastPathComponent, language: (path as NSString).pathExtension, text: text,
                               digest: contents.record.contentDigest, byteCount: data.count,
                               notice: text == nil ? "A binary file: only text files show here." : nil))
        case .diff:
            let entries = contents.record.manifest.entries
            let text = entries.sorted { $0.path < $1.path }.compactMap { entry -> String? in
                guard let data = bytes[entry.path], let body = String(data: data, encoding: .utf8) else { return nil }
                return entry.mediaType?.contains("diff") == true ? body : "--- \(entry.path)\n" + body
            }.joined(separator: "\n")
            return .diff(.init(title: title, diff: text, digest: contents.record.contentDigest, files: entries.count, truncated: false))
        case .browser:
            guard let browser = SharedPortal.decode(SharedPortal.BrowserPayload.self, name: SharedPortal.BrowserPayload.name, from: bytes) else { return nil }
            var frame: Collaboration.LiveTile.Frame?
            if let encoded = SharedPortal.payload(bytes)[SharedPortal.BrowserPayload.stillEntry], let image = Data(base64Encoded: encoded),
               let size = NSImage(data: image)?.size {
                frame = .init(jpeg: image, width: Double(size.width), height: Double(size.height), sequence: contents.record.sequence)
            }
            return .browser(.init(url: browser.url, title: browser.title, reach: browser.mode == .live ? .public : .private, frame: frame))
        case .terminal:
            return nil
        }
    }

    override func apply(state: SharedPortalItemState) {
        super.apply(state: state)
        if case .stopped = state { body.stop() }
    }

    override var hoverActions: [SharedPortalHoverAction] {
        guard liveKind == .diff, case .live = itemState, let revision = latest?.record.manifest.id else { return [] }
        func review(_ verdict: Collaboration.Artifact.Verdict, _ label: String) -> SharedPortalHoverAction {
            .init(title: label, symbolName: verdict == .approve ? "checkmark" : "arrow.uturn.backward") { [weak self] in
                guard let self, let guest = self.guest else { return }
                Task { @MainActor in
                    if (try? await guest.review(object: self.entry.object, revision: revision, verdict: verdict)) != nil {
                        self.reviewed = verdict.rawValue
                    }
                }
            }
        }
        return [review(.approve, "Approve"), review(.requestChanges, "Request changes")]
    }

    override var qaFacts: [String: String] {
        var facts = ["editable": "false", "text": body.qaText, "revision": String(latest?.record.sequence ?? 0)]
        if liveKind == .diff { facts["reviewed"] = reviewed }
        if liveKind == .browser {
            facts["mode"] = body.browserMode == .follow ? "live" : "still"
            if body.browserMode != .follow { facts["badge"] = "Still" }
            facts["url"] = body.followedURL ?? body.state.flatMap { if case .browser(let b) = $0.payload { return b.url }; return nil } ?? ""
            // What the guest sees on top: a browser's own header and address bar.
            if let chrome = body.qaBrowserChrome {
                facts["chrome"] = "browser"
                facts["pageTitle"] = chrome.title
                facts["address"] = chrome.urlField.stringValue
                facts["status"] = chrome.statusLabel.stringValue
            }
            if let web = body.qaWebView { facts["store"] = web.configuration.websiteDataStore.isPersistent ? "persistent" : "ephemeral" }
            facts["wandered"] = body.wandered ? "true" : "false"
        }
        return facts
    }

    override func layout() {
        super.layout()
        body.frame = bounds
    }
}
