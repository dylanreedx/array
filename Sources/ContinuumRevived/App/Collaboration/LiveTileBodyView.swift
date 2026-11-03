import AppKit
import WebKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient

/// What a teammate sees of someone's shared note, file, diff, browser or
/// terminal (`.plans/105-collaboration/SHARE-KINDS.md`). Self-contained: give
/// it a connected `SharedAreaController` and the item's object, and it reads
/// the lane, draws the kind and sends this person's input. The `.sharedTile`
/// tile hosts one; the portal hosts one per item at its own size.
///
/// - note: an editor; both people's keystrokes merge (`Collaboration.NoteText`).
/// - file, diff: read only, re-drawn whenever the owner's copy changes.
/// - browser: a public page loads here and follows the owner's navigation; a
///   private one (or a public one that would not load) shows the owner's page
///   as pictures, and a click or scroll on it reaches the owner's page.
/// - terminal: a read-only mirror. Typing stays on the owner's Mac.
@MainActor
final class LiveTileBodyView: NSView, NSTextViewDelegate, WKNavigationDelegate {
    enum BrowserMode: String { case waiting, follow, frames }

    let kind: Collaboration.LiveTile.Kind
    var hostName: String { didSet { if hostName != oldValue { renderCaption() } } }
    private weak var controller: SharedAreaController?
    private var object: SharedArea.ID<SharedArea.Object>?
    private let replicaID: String
    private var reader: Task<Void, Never>?
    private var flusher: Task<Void, Never>?
    private(set) var state: Collaboration.LiveTile.State?
    private var eventCursor: UInt64?
    private(set) var lastUpdate: Date?
    /// Nothing more is sent: sharing stopped, or this install may not.
    var inputEnabled = true { didSet { applyEditability() } }
    /// Inside a portal: read only, and a private page is a still, not a stream.
    var inPortal = false { didSet { if inPortal != oldValue { installBrowserChrome() }; renderCaption() } }

    // Note
    private var replica: Collaboration.NoteText.Replica?
    private var outbox: [Collaboration.LiveTile.EventBody] = []
    private var applyingRemote = false

    // Views
    private let caption = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var markdownSurface: MarkdownDocumentSurface?
    private var documentSurface: NSView?
    private var codeEditor: CodeEditorHostView?
    private let editorDocumentID = UUID().uuidString
    private var diffModel: GitDiffModel?
    private let frameView = LiveTileFrameView()
    /// A terminal that streams draws through this (`SharedTerminalMirrorView`).
    private let terminalMirror: SharedTerminalMirrorView?
    private var webView: WKWebView?
    private(set) var browserMode: BrowserMode = .waiting
    private(set) var followedURL: String?
    private var followFailed: String?
    /// The browser's own top: header (in a portal), back, forward, reload,
    /// the page icon and the address bar, as the owner's tile draws them.
    private var browserChrome: SharedBrowserChromeView?
    /// The navigation this view started to follow the owner; any other main
    /// frame commit is the guest clicking somewhere of their own.
    private var followNavigation: WKNavigation?
    /// The guest clicked away from the owner's page. The owner's next new
    /// address brings them back; so does "Back to <owner>'s page".
    private(set) var wandered = false
    /// The title shown when the owner's page has none (the portal item's).
    var fallbackTitle = "" { didSet { renderCaption() } }
    private var scrollAccumulator = CGPoint.zero
    private var scrollFlush: Task<Void, Never>?

    override var isFlipped: Bool { true }

    init(kind: Collaboration.LiveTile.Kind, hostName: String, replicaID: String = UUID().uuidString) {
        self.kind = kind; self.hostName = hostName; self.replicaID = replicaID
        terminalMirror = kind == .terminal ? SharedTerminalMirrorView() : nil
        super.init(frame: .zero)
        caption.font = .token(.caption); caption.lineBreakMode = .byTruncatingTail
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = kind == .note ? .token(.body) : .token(.bodyMono)
        textView.drawsBackground = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        frameView.onClick = { [weak self] x, y in self?.send(.browserClick(x: x, y: y)) }
        frameView.onScroll = { [weak self] dx, dy in self?.accumulateScroll(dx: dx, dy: dy) }
        frameView.isHidden = true
        // A browser shows a page or pictures, never text.
        scroll.isHidden = kind == .browser
        addSubview(caption); addSubview(scroll); addSubview(frameView)
        if let terminalMirror { terminalMirror.isHidden = true; addSubview(terminalMirror) }
        installBrowserChrome()
        applyEditability()
        renderCaption()
        applyAppearance()
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lane

    /// Start reading `object` through `controller`. Calling it again with
    /// another controller (a new link's access) restarts the reader.
    func attach(controller: SharedAreaController, object: SharedArea.ID<SharedArea.Object>) {
        if self.controller === controller, self.object == object, reader != nil { return }
        stop()
        self.controller = controller; self.object = object
        terminalMirror?.attach(controller: controller, object: object)
        reader = Task { [weak self] in
            while let self, !Task.isCancelled {
                let failed = await self.readOnce()
                if failed { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        flushSoon()
    }
    var isReading: Bool { reader != nil }

    func stop() {
        reader?.cancel(); reader = nil
        terminalMirror?.stop()
        flusher?.cancel(); flusher = nil
        scrollFlush?.cancel(); scrollFlush = nil
    }

    /// One long-poll. Returns true when it failed and the loop should back off.
    private func readOnce() async -> Bool {
        guard let controller, let object, controller.status == .connected else { return true }
        // A note reader behind the log's floor takes the whole state again.
        let request = Collaboration.LiveTile.ReadRequest(generation: state?.generation, revision: state?.revision,
                                                         eventsAfter: eventCursor, waitMilliseconds: state == nil ? 0 : 20_000)
        do {
            let read = try await controller.readLiveTile(object: object, request: request)
            // A relay that restarted counts events from zero again.
            if let cursor = eventCursor, read.eventHead < cursor { eventCursor = read.eventHead }
            if let next = read.state { apply(state: next) }
            if kind == .note, let cursor = eventCursor, cursor < read.eventFloor {
                // Missed events: ask again for the state, which covers them.
                self.state = nil; eventCursor = nil
                return false
            }
            if !read.events.isEmpty { apply(events: read.events) }
            if let last = read.events.last?.sequence { eventCursor = max(eventCursor ?? 0, last) }
            else if eventCursor == nil, state != nil, kind != .note { eventCursor = read.eventHead }
            if state == nil { return true }
            return false
        } catch {
            return true
        }
    }

    private func apply(state next: Collaboration.LiveTile.State) {
        guard next.kind == kind else { return }
        state = next
        lastUpdate = Date()
        switch next.payload {
        case .note(let note):
            // A portal revision is the whole text, not this editor's history:
            // it replaces the replica. Merging it would interleave two texts.
            if replica == nil || inPortal {
                replica = Collaboration.NoteText.Replica(snapshot: note.snapshot, replica: replicaID)
                eventCursor = note.eventsThrough
                applyEditability()
            } else {
                replica?.merge(note.snapshot)
            }
            // Edits typed before the first state arrived are folded in now.
            showReplicaText()
        case .file(let file):
            setReadOnlyText(file.text ?? file.notice ?? "")
            showFile(file)
        case .diff(let diff):
            setReadOnlyText(diff.diff)
            diffModel = GitDiffParser.parse(diff.diff)
            textView.isRichText = true
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.lineBreakMode = .byClipping
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            renderDiff()
        case .terminal(let terminal):
            if let screen = terminal.screen, let terminalMirror {
                terminalMirror.isHidden = false; scroll.isHidden = true
                terminalMirror.take(screen)
            } else {
                setReadOnlyText(terminal.text, scrollToEnd: true)
            }
        case .browser(let browser):
            applyBrowser(browser)
        }
        renderCaption()
    }

    private func apply(events: [Collaboration.LiveTile.Event]) {
        guard kind == .note, replica != nil else { return }
        var ops: [Collaboration.NoteText.Op] = []
        for event in events { if case .noteOps(let batch) = event.body { ops += batch } }
        guard !ops.isEmpty else { return }
        replica?.apply(ops)
        lastUpdate = Date()
        showReplicaText()
    }

    /// Show a state that came another way: a portal item's revision, or the
    /// render check's fixture. Nothing is read or sent.
    func show(_ state: Collaboration.LiveTile.State) { apply(state: state) }

    // MARK: Note editing

    func textDidChange(_ notification: Notification) {
        guard kind == .note, !applyingRemote, inputEnabled, var replica else { return }
        markdownSurface?.draftDidChange(textView.string)
        let ops = replica.edit(to: textView.string)
        self.replica = replica
        guard !ops.isEmpty else { return }
        for batch in Collaboration.NoteText.batches(ops, maxBytes: 96 * 1024) { outbox.append(.noteOps(batch)) }
        flushSoon()
    }

    private func showReplicaText() {
        guard let replica else { return }
        let next = replica.text
        if markdownSurface == nil {
            textView.font = .token(.bodyMono)
            scroll.autohidesScrollers = true
            let surface = MarkdownDocumentSurface(textView: textView, sourceScrollView: scroll,
                initialDraft: next, mode: .split, theme: { [weak self] in self?.effectiveTokenTheme ?? .dark })
            markdownSurface = surface
            installDocument(surface.activeBody)
        }
        guard next != textView.string else { markdownSurface?.draftDidChange(next); return }
        // Replace only what changed, so the caret and selection stay put
        // around a teammate's edit, as they would around a local one.
        applyingRemote = true
        LiveTileTextSplice.replace(in: textView, with: next)
        applyingRemote = false
        markdownSurface?.draftDidChange(next)
    }

    private func send(_ body: Collaboration.LiveTile.EventBody) {
        guard inputEnabled else { return }
        outbox.append(body)
        flushSoon()
    }

    private func flushSoon() {
        guard flusher == nil, !outbox.isEmpty else { return }
        flusher = Task { [weak self] in
            while let self, !Task.isCancelled, !self.outbox.isEmpty {
                guard let controller = self.controller, let object = self.object, controller.status == .connected, self.inputEnabled else {
                    try? await Task.sleep(for: .milliseconds(500)); continue
                }
                let body = self.outbox[0]
                do {
                    _ = try await controller.appendLiveTileEvent(object: object, body: body)
                    if !self.outbox.isEmpty { self.outbox.removeFirst() }
                    self.sentEvents += 1
                } catch {
                    self.lastSendError = "\(error)"
                    // A refusal (read-only, stopped) drops it; a network failure retries.
                    if case CollaborationClientError.server(let status, _)? = error as? CollaborationClientError,
                       (400..<500).contains(status), status != 409 {
                        self.outbox.removeFirst()
                    } else {
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
            }
            self?.flusher = nil
        }
    }
    private(set) var sentEvents = 0
    private(set) var lastSendError: String?

    // MARK: Read-only kinds

    private func setReadOnlyText(_ text: String, scrollToEnd: Bool = false) {
        guard textView.string != text else { return }
        let visible = scroll.contentView.bounds.origin
        textView.string = text
        textView.textColor = TextToken.textPrimary.color.nsColor(in: self)
        if scrollToEnd { textView.scrollToEndOfDocument(nil) }
        else { scroll.contentView.scroll(to: visible); scroll.reflectScrolledClipView(scroll.contentView) }
    }

    /// The diff's +/- colours, as token runs over the text's one token colour
    /// (the appearance census reads both).
    private func colourDiffLines() {
        guard let storage = textView.textStorage else { return }
        let text = textView.string as NSString
        let secondary = TextToken.textSecondary.color.nsColor(in: self)
        let added = AccentToken.accentDone.color.nsColor(in: self)
        let removed = AccentToken.accentFailed.color.nsColor(in: self)
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byLines) { line, range, _, _ in
            guard let line else { return }
            let colour: NSColor?
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("@@") {
                colour = secondary
            } else if line.hasPrefix("+") { colour = added }
            else if line.hasPrefix("-") { colour = removed }
            else { colour = nil }
            if let colour { storage.addAttribute(.foregroundColor, value: colour, range: range) }
        }
    }

    private func installDocument(_ view: NSView) {
        if documentSurface !== view {
            if documentSurface !== scroll { documentSurface?.removeFromSuperview() }
            documentSurface = view
            addSubview(view)
            scroll.isHidden = view !== scroll
            needsLayout = true
        }
    }

    private func showFile(_ file: Collaboration.LiveTile.File) {
        guard let text = file.text else {
            installDocument(scroll)
            return
        }
        if file.language == "markdown" || ["md", "markdown"].contains((file.name as NSString).pathExtension.lowercased()) {
            if markdownSurface == nil {
                markdownSurface = MarkdownDocumentSurface(textView: textView, sourceScrollView: scroll,
                    initialDraft: text, mode: .preview, theme: { [weak self] in self?.effectiveTokenTheme ?? .dark })
            }
            markdownSurface?.replaceDraft(text)
            installDocument(markdownSurface!.activeBody)
        } else {
            if codeEditor == nil {
                codeEditor = CodeEditorHostView(frame: .zero)
                codeEditor?.setPreferences(EditorPreferences(), isDark: effectiveTokenTheme == .dark)
            }
            let editor = codeEditor!
            installDocument(editor)
            editor.loadDocument(documentID: editorDocumentID, text: text,
                language: FileTileNSView.codeMirrorLanguage(FilePreview.sourceLanguage(forPath: file.name)),
                revision: state?.revision ?? 0, readOnly: true)
        }
    }

    private func renderDiff() {
        guard let diffModel else { return }
        textView.textStorage?.setAttributedString(DiffReviewTileNSView.render(diffModel, theme: effectiveTokenTheme))
    }

    // MARK: Browser

    private func applyBrowser(_ browser: Collaboration.LiveTile.Browser) {
        let follow = browser.reach == .public && browser.url != nil && followFailed == nil
        if follow, let url = browser.url {
            browserMode = .follow
            let web = ensureWebView()
            // The owner moving to a new page brings a wandered guest back; a
            // revision of the same page (a new title) leaves them where they are.
            if followedURL != url, let target = URL(string: url) {
                followedURL = url
                wandered = false
                followNavigation = web.load(URLRequest(url: target))
            }
        } else {
            browserMode = browser.frame == nil ? .waiting : .frames
            if let frame = browser.frame { frameView.show(frame) }
        }
        webView?.isHidden = browserMode != .follow
        frameView.isHidden = browserMode != .frames
        scroll.isHidden = true
        needsLayout = true
    }

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        // A store of its own that ends with the view: the owner's cookies never
        // reach this Mac, and the owner's navigation never runs on the guest's
        // own signed-in sessions either.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: bounds, configuration: configuration)
        web.navigationDelegate = self
        addSubview(web)
        webView = web
        return web
    }

    /// Leaves the guest's own page for the one the owner is on.
    @objc func returnToHost() {
        guard wandered, let url = followedURL, let target = URL(string: url), let webView else { return }
        wandered = false
        followNavigation = webView.load(URLRequest(url: target))
        renderCaption()
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard navigation !== followNavigation, browserMode == .follow, !wandered else { renderCaption(); return }
            wandered = true
            renderCaption()
        }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { renderCaption() }
    }

    /// A public page that does not load here (signed in, or blocked) falls
    /// back to the owner's pictures.
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            // Only the owner's page failing here means it cannot load on this Mac.
            // A load the guest's own click cut short is not a failure.
            guard navigation === followNavigation, (error as NSError).code != NSURLErrorCancelled else { return }
            fallBackToFrames("\(error.localizedDescription)")
        }
    }
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let status = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 200
        MainActor.assumeIsolated {
            if navigationResponse.isForMainFrame, !wandered, navigationResponse.response.url?.absoluteString == followedURL,
               status == 401 || status == 403 { fallBackToFrames("HTTP \(status)") }
            decisionHandler(.allow)
        }
    }
    private func fallBackToFrames(_ reason: String) {
        guard followFailed == nil else { return }
        followFailed = reason
        if case .browser(let browser)? = state?.payload { applyBrowser(browser) }
        renderCaption()
    }

    private func accumulateScroll(dx: CGFloat, dy: CGFloat) {
        scrollAccumulator.x += dx; scrollAccumulator.y += dy
        guard scrollFlush == nil else { return }
        scrollFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            let delta = self.scrollAccumulator
            self.scrollAccumulator = .zero; self.scrollFlush = nil
            if delta != .zero { self.send(.browserScroll(dx: Double(delta.x), dy: Double(delta.y))) }
        }
    }

    // MARK: Chrome

    private func applyEditability() {
        // A note is editable once its text has arrived: before that there is
        // nothing for a keystroke to land in.
        let editable = kind == .note && inputEnabled && replica != nil
        textView.isEditable = editable
        textView.isSelectable = true
        frameView.acceptsInput = kind == .browser && inputEnabled
    }

    private func renderCaption() {
        var text: String
        switch state?.payload {
        case .note(let note)?: text = note.title.isEmpty ? "Note" : note.title
            text += inPortal ? " · live · read only here" : " · you and \(hostName) can both edit"
        case .file(let file)?: text = file.name + " · " + ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file)
            + " · follows \(hostName)'s saves · read only"
        case .diff(let diff)?: text = diff.title + " · \(diff.files) file\(diff.files == 1 ? "" : "s")" + (diff.truncated ? " · cut short" : "")
            + " · live"
        case .terminal(let terminal)?: text = (terminal.title.isEmpty ? "Terminal" : terminal.title) + " · read only · typing stays on \(hostName)'s Mac"
        case .browser(let browser)?:
            let where_ = browser.url ?? "a page"
            switch browserMode {
            case .follow: text = "\(hostName)'s browser · \(where_) · loaded on your Mac, following \(hostName)"
            case .frames: text = inPortal ? "Still · \(hostName)'s browser · \(where_)"
                : "\(hostName)'s browser · \(where_) · live from \(hostName)'s Mac · clicks and scrolls go to it"
            case .waiting: text = "\(hostName)'s browser · \(where_) · waiting for a picture"
            }
        case nil: text = "Connecting to \(hostName)'s \(Self.noun(kind))…"
        }
        if caption.stringValue != text { caption.stringValue = text }
        setAccessibilityLabel(text)
        renderBrowserChrome()
    }

    private func installBrowserChrome() {
        guard kind == .browser else { return }
        browserChrome?.removeFromSuperview()
        let chrome = SharedBrowserChromeView(showsTitleBar: inPortal)
        chrome.backToHostButton.target = self
        chrome.backToHostButton.action = #selector(returnToHost)
        addSubview(chrome)
        browserChrome = chrome
        caption.isHidden = true
        needsLayout = true
    }

    /// What the browser's top says: the page's title and address, and whether
    /// this is the owner's page loading here, a still, or the guest's own page.
    private func renderBrowserChrome() {
        guard let browserChrome else { return }
        var title = fallbackTitle, address = "", hasPage = false, status: String
        var back: String?
        if case .browser(let browser)? = state?.payload {
            if !browser.title.isEmpty { title = browser.title }
            address = browser.url ?? ""
        }
        switch browserMode {
        case .follow:
            hasPage = webView?.url != nil
            if wandered {
                address = webView?.url?.absoluteString ?? address
                title = webView?.title.flatMap { $0.isEmpty ? nil : $0 } ?? title
                status = "Your page"
                back = "Back to \(hostName)'s page"
            } else {
                status = "Following \(hostName)"
            }
        case .frames:
            hasPage = true
            status = inPortal ? "Still" : "Live from \(hostName)'s Mac"
        case .waiting:
            status = state == nil ? "Connecting…" : followFailed != nil ? "Didn't load here" : inPortal ? "Still" : "Waiting"
        }
        browserChrome.update(title: title, address: address, hasPage: hasPage, status: status, backTitle: back)
        frameView.placeholder = followFailed != nil
            ? "This page didn't load on your Mac, and \(hostName) hasn't sent a picture of it yet."
            : "The page is on \(hostName)'s Mac. A picture shows here once \(hostName) has it on screen."
    }

    static func noun(_ kind: Collaboration.LiveTile.Kind) -> String {
        switch kind { case .note: "note"; case .file: "file"; case .diff: "diff"; case .browser: "browser"; case .terminal: "terminal" }
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 10
        caption.frame = NSRect(x: inset, y: 6, width: max(0, bounds.width - 2 * inset), height: 16)
        let top = browserChrome?.height ?? 26
        browserChrome?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        let body = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        if scroll.superview === self, scroll.frame != body { scroll.frame = body }
        if let documentSurface, documentSurface.frame != body { documentSurface.frame = body }
        frameView.frame = body
        terminalMirror?.frame = body
        webView?.frame = body
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        caption.textColor = TextToken.textSecondary.color.nsColor(in: self)
        let primary = TextToken.textPrimary.color.nsColor(in: self)
        textView.textColor = primary
        // An empty text view reads its colour back from its typing attributes.
        textView.typingAttributes[.foregroundColor] = primary
        markdownSurface?.applyTheme()
        codeEditor?.setPreferences(EditorPreferences(), isDark: effectiveTokenTheme == .dark)
        if kind == .diff { renderDiff() }
        textView.insertionPointColor = TextToken.textPrimary.color.nsColor(in: self)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        SurfaceToken.tileBody.color.nsColor(in: self).setFill()
        bounds.fill()
        LineToken.separator.color.nsColor(in: self).setFill()
        let top = browserChrome?.height ?? 26
        NSRect(x: 0, y: top - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: QA


    var qaText: String { textView.string }
    /// The shared content itself, under the caption: what the parity witness
    /// compares with the owner's tile body. Nil for a browser, whose top is
    /// the browser's own chrome.
    var qaContentSurface: NSView? { kind == .browser ? nil : (documentSurface ?? scroll) }
    var qaCaption: String { caption.stringValue }
    var qaEditable: Bool { textView.isEditable }
    var qaFrameSequence: UInt64 { frameView.frame_?.sequence ?? 0 }
    var qaFrameView: LiveTileFrameView { frameView }
    var qaTextView: NSTextView { textView }
    var qaTerminalMirror: SharedTerminalMirrorView? { terminalMirror?.isHidden == false ? terminalMirror : nil }
    var qaPendingEvents: Int { outbox.count }
    var qaWebView: WKWebView? { webView }
    var qaBackToHost: NSButton? { browserChrome?.backToHostButton }
    var qaBrowserChrome: SharedBrowserChromeView? { browserChrome }
}

/// The owner's page as a picture, fitted to the tile. A click or a scroll on
/// it is mapped to the same point of the owner's page.
@MainActor
final class LiveTileFrameView: NSView {
    var onClick: ((Double, Double) -> Void)?
    var onScroll: ((CGFloat, CGFloat) -> Void)?
    var acceptsInput = true
    /// What shows before the first picture arrives.
    var placeholder = "Waiting for a picture of the page…" { didSet { if placeholder != oldValue, image == nil { needsDisplay = true } } }
    private(set) var frame_: Collaboration.LiveTile.Frame?
    private var image: NSImage?
    override var isFlipped: Bool { true }

    func show(_ frame: Collaboration.LiveTile.Frame) {
        guard frame.sequence != frame_?.sequence || frame.jpeg != frame_?.jpeg else { return }
        frame_ = frame
        image = NSImage(data: frame.jpeg)
        needsDisplay = true
    }

    /// Where the page sits in this view, aspect-fitted.
    var imageRect: NSRect {
        guard let frame = frame_, frame.width > 0, frame.height > 0 else { return .zero }
        let scale = min(bounds.width / frame.width, bounds.height / frame.height)
        let size = NSSize(width: frame.width * scale, height: frame.height * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
    }
    /// A point in this view, as a point of the owner's page.
    func pagePoint(for point: NSPoint) -> (Double, Double)? {
        let rect = imageRect
        guard let frame = frame_, rect.contains(point), rect.width > 0 else { return nil }
        return (Double((point.x - rect.minX) / rect.width) * frame.width, Double((point.y - rect.minY) / rect.height) * frame.height)
    }
    /// The inverse, for a check that clicks a known point of the page.
    func viewPoint(forPage x: Double, _ y: Double) -> NSPoint? {
        let rect = imageRect
        guard let frame = frame_, frame.width > 0 else { return nil }
        return NSPoint(x: rect.minX + CGFloat(x / frame.width) * rect.width, y: rect.minY + CGFloat(y / frame.height) * rect.height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard acceptsInput, let point = pagePoint(for: convert(event.locationInWindow, from: nil)) else { return }
        onClick?(point.0, point.1)
    }
    override func scrollWheel(with event: NSEvent) {
        guard acceptsInput, let frame = frame_, imageRect.width > 0 else { return }
        let scale = frame.width / Double(imageRect.width)
        onScroll?(-event.scrollingDeltaX * scale, -event.scrollingDeltaY * scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        SurfaceToken.tileBody.color.nsColor(in: self).setFill()
        bounds.fill()
        guard let image else {
            let text = placeholder as NSString
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.token(.caption), .paragraphStyle: paragraph,
                                                             .foregroundColor: TextToken.textSecondary.color.nsColor(in: self)]
            let width = max(0, min(bounds.width - 48, 320))
            let size = text.boundingRect(with: NSSize(width: width, height: bounds.height), options: [.usesLineFragmentOrigin], attributes: attributes).size
            text.draw(with: NSRect(x: (bounds.width - width) / 2, y: bounds.midY - size.height / 2, width: width, height: size.height + 2),
                      options: [.usesLineFragmentOrigin], attributes: attributes)
            return
        }
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}
