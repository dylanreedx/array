import AppKit
import WebKit
import UniformTypeIdentifiers
import ContinuumRevivedCore

struct BoardAgentChoice {
    let id: AgentID
    let name: String
    let detail: String
    let tileID: UUID?
}

/// Local task document. Every save goes through the board's undoable reducer.
@MainActor
final class BoardTaskDetailController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private weak var tile: KanbanTileNSView?
    private let cardID: UUID
    private var baseline: BoardTaskContent
    private var draft: BoardTaskContent
    private var saveTask: Task<Void, Never>?
    private var importing = 0
    private var ready = false
    private var presentationRequested = false
    private var openAssignee = false
    private var saving = false
    private let web: WKWebView
    private let images: BoardTaskImageScheme
    private var overlay: BoardTaskModalView?
    private weak var previousResponder: NSResponder?
    private(set) weak var window: NSWindow?

    static func dismissPresented(in window: NSWindow?) {
        (window?.contentView?.subviews.first { $0 is BoardTaskModalView } as? BoardTaskModalView)?.onDismiss?()
    }
    static func isPresented(in window: NSWindow?) -> Bool {
        window?.contentView?.subviews.contains { $0 is BoardTaskModalView } == true
    }


    init(tile: KanbanTileNSView, card: BoardCard) {
        self.tile = tile; cardID = card.id
        baseline = BoardTaskContent(card: card); draft = baseline
        images = BoardTaskImageScheme(store: tile.taskAttachmentStore, boardID: tile.board.id)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(images, forURLScheme: "array-task-image")
        web = WKWebView(frame: .zero, configuration: configuration)
        // A newly-created WKWebView paints its default surface before the local
        // editor and task snapshot arrive. Keep it covered by the modal shell
        // until both scripts have run so opening details is one stable frame.
        web.isHidden = true
        super.init()
        configuration.userContentController.add(self, name: "taskEditor")
        web.navigationDelegate = self
        refreshImageScope()
        if let url = Self.editorURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
    /// Match CodeEditorHostView's installed-app and bare-check layouts. SwiftPM's
    /// generated Bundle.module fallback points into the build machine's checkout.
    static var editorURL: URL? {
        let name = "continuum-revived_ContinuumRevived.bundle"
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(name),
                          Bundle.main.bundleURL.appendingPathComponent(name)].compactMap { $0 }
        return candidates.lazy.compactMap(Bundle.init(url:)).first?
            .url(forResource: "index", withExtension: "html", subdirectory: "TaskEditor")
    }
    func present(openAssignee: Bool = false) {
        guard overlay == nil, !presentationRequested, let window = tile?.window else { return }
        self.openAssignee = openAssignee
        self.window = window
        previousResponder = window.firstResponder
        presentationRequested = true
        if ready { loadAndMount() }
    }
    private func loadAndMount() {
        guard presentationRequested, overlay == nil else { return }
        call("load", [snapshot()])
        web.evaluateJavaScript("document.getElementById('title').focus()") { [weak self] _, _ in
            guard let self, self.presentationRequested, self.overlay == nil,
                  let window = self.window, let host = window.contentView else { return }
            if self.openAssignee {
                self.web.evaluateJavaScript("document.getElementById('assignee').click()", completionHandler: nil)
            }
            let modal = BoardTaskModalView(editor: self.web)
            modal.onDismiss = { [weak self] in self?.requestClose() }
            modal.frame = host.bounds
            modal.autoresizingMask = [.width, .height]
            modal.revealEditor()
            host.addSubview(modal, positioned: .above, relativeTo: nil)
            self.overlay = modal
            self.presentationRequested = false
            modal.layoutSubtreeIfNeeded()
            window.makeFirstResponder(self.web)
            NSAccessibility.post(element: modal, notification: .layoutChanged)
        }
    }
    func finishBeforeOpeningAnother() -> Bool {
        guard flush() else { return false }
        dismiss()
        return true
    }
    private func dismiss(restoreFocus: Bool = true) {
        saveTask?.cancel()
        presentationRequested = false
        overlay?.removeFromSuperview()
        overlay = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "taskEditor")
        if restoreFocus, let previous = previousResponder as? NSView, previous.window === window {
            window?.makeFirstResponder(previous)
        }
        previousResponder = nil
    }

    private func call(_ method: String, _ arguments: [Any] = []) {
        guard ready, let data = try? JSONSerialization.data(withJSONObject: arguments), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.taskEditor.\(method)(...\(json))", completionHandler: nil)
    }
    private func snapshot() -> [String: Any] {
        guard let tile, let card = tile.board.card(cardID) else { return [:] }
        let agents = tile.taskAgents?() ?? []
        return ["title": draft.title, "body": draft.body,
                "attachments": draft.attachments.map(Self.imageJSON),
                "agents": agents.map { ["id": $0.id.rawValue.uuidString, "name": $0.name, "detail": $0.detail] },
                "columns": tile.board.orderedColumns.map { ["id": $0.id.uuidString, "name": $0.name] },
                "columnID": card.columnId.uuidString,
                "assigneeID": card.assignee.map { $0.rawValue.uuidString } as Any? ?? NSNull(),
                "assigneeName": tile.assigneeName(for: card) as Any? ?? NSNull()]
    }
    private static func imageJSON(_ image: BoardAttachment) -> [String: Any] {
        ["id": image.id.uuidString, "filename": image.filename, "url": image.imageURL]
    }
    func refresh() {
        guard !saving else { return }
        guard let card = tile?.board.card(cardID) else { call("error", ["This task was removed. Your open edits are still here."]); return }
        if draft == baseline {
            baseline = BoardTaskContent(card: card); draft = baseline
            refreshImageScope(); call("load", [snapshot()])
        } else { call("metadata", [snapshot()]) }
    }
    private func refreshImageScope() { images.attachments = Dictionary(uniqueKeysWithValues: draft.attachments.map { ($0.id, $0) }) }
    private func changed(_ value: [String: Any]) {
        if let title = value["title"] as? String { draft.title = title }
        if let body = value["body"] as? String { draft.body = body }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            _ = self?.flush()
        }
    }
    @discardableResult private func flush() -> Bool {
        saveTask?.cancel()
        guard importing == 0 else { call("error", ["Wait for the images to finish importing."]); return false }
        guard draft != baseline else { return true }
        guard let tile, let runtime = tile.boardRuntime else { call("error", ["The board is no longer available."]); return false }
        let submitted = draft
        saving = true
        let outcome = runtime.apply(.editTask(id: cardID, expected: baseline, content: draft), to: tile.board.id, originatingView: tile)
        saving = false
        switch outcome {
        case .applied, .rebased:
            if let card = tile.board.card(cardID) { baseline = BoardTaskContent(card: card); draft = baseline }
            refreshImageScope()
            if draft != submitted { call("load", [snapshot()]) }
            call("saved"); return true
        case .rejected(.contentConflict): call("error", ["This task changed elsewhere. Choose which version to keep.", true])
        case .rejected(let error): call("error", [error.description])
        case .persistenceFailed(let error): call("error", ["Could not save: " + error])
        case .rejectedCardHeldByPointer: call("error", ["Finish dragging this task before saving."])
        }
        return false
    }
    /// Native shortcuts/backdrop events may arrive before WebKit's last change
    /// message. Read the live document before tearing down its message handler.
    private func requestClose() {
        guard ready else { closeEditor(); return }
        web.evaluateJavaScript("window.taskEditor.snapshot()") { [weak self] result, error in
            guard let self else { return }
            guard error == nil, let content = result as? [String: Any] else {
                self.call("error", ["Could not read your latest edits. Try closing again."])
                return
            }
            self.changed(content)
            self.closeEditor()
        }
    }
    private func closeEditor(restoreFocus: Bool = true) {
        guard flush() else { return }
        dismiss(restoreFocus: restoreFocus)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any], let type = value["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            let dark = web.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if !dark { call("theme", [["bg":"#ffffff", "card":"#f5f6f8", "text":"#202329", "muted":"#6b7079", "line":"#e2e5ea", "accent":"#4262dc", "mode":"light"]]) }
            loadAndMount()
        case "change": changed(value)
        case "close": closeEditor()
        case "refreshAgents": call("metadata", [snapshot()])
        case "assign":
            guard let tile else { return }
            let id = (value["agentID"] as? String).flatMap(UUID.init(uuidString:)).map(AgentID.init(rawValue:))
            if let error = tile.onTaskAssign?(cardID, id) { call("error", [error]) }
            call("metadata", [snapshot()])
        case "status":
            guard let tile, let id = (value["columnID"] as? String).flatMap(UUID.init(uuidString:)) else { return }
            let outcome = tile.boardRuntime?.apply(.moveCard(id: cardID, toColumn: id, after: tile.board.orderedCards(in: id).last(where: { $0.id != cardID })?.id, before: nil), to: tile.board.id)
            if case .applied = outcome {} else { call("error", ["Could not change status."]) }
            call("metadata", [snapshot()])
        case "reload":
            if let card = tile?.board.card(cardID) { baseline = BoardTaskContent(card: card); draft = baseline; refreshImageScope(); call("load", [snapshot()]); call("saved") }
        case "keep":
            if let card = tile?.board.card(cardID) { baseline = BoardTaskContent(card: card); _ = flush() }
        case "prepare":
            guard flush(), let tile else { return }
            Task { @MainActor [weak self] in
                if let error = await tile.onTaskPrepare?(self?.cardID ?? UUID()) { self?.call("error", [error]) }
                else { self?.closeEditor(restoreFocus: false) }
            }
        case "createAgent":
            if flush() {
                if tile?.onTaskCreateAgent?() == true { closeEditor(restoreFocus: false) }
                else { call("error", ["Could not create an agent in this board’s project."]) }
            }
        case "pickImages": pickImages(inline: value["inline"] as? Bool ?? false)
        case "image":
            guard let encoded = value["data"] as? String, encoded.count < 45_000_000, let data = Data(base64Encoded: encoded) else { call("error", ["The image is too large or unreadable."]); return }
            importImage(data, filename: value["filename"] as? String ?? "Screenshot.png", inline: value["inline"] as? Bool ?? false)
        case "removeImage":
            if let id = (value["attachmentID"] as? String).flatMap(UUID.init(uuidString:)) { draft.attachments.removeAll { $0.id == id }; refreshImageScope(); changed(value) }
        default: break
        }
    }
    private func pickImages(inline: Bool) {
        guard let window else { return }
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.image]; picker.allowsMultipleSelection = true
        picker.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK else { return }
            for url in picker.urls {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
                      let data = try? Data(contentsOf: url) else { self?.call("error", ["Could not read image, or it exceeds 32 MB."]); continue }
                self?.importImage(data, filename: url.lastPathComponent, inline: inline)
            }
        }
    }
    private func importImage(_ data: Data, filename: String, inline: Bool) {
        guard data.count <= 32 * 1024 * 1024,
              let decoded = ComposerDecodedImagePasteboardItem(data: data, contentType: UTType.png.identifier, suggestedFilename: filename),
              let tile, let store = tile.taskAttachmentStore else { call("error", ["Choose a supported image up to 32 MB."]); return }
        importing += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { importing -= 1 }
            do {
                let validation = try AgentComposerImageValidation(validatedContentType: decoded.managedContentType, pixelWidth: decoded.pixelWidth, pixelHeight: decoded.pixelHeight, byteCount: decoded.byteCount)
                let attachment = try await store.importImage(data, filename: decoded.suggestedFilename, validation: validation, boardID: tile.board.id)
                draft.attachments.append(attachment); refreshImageScope()
                call("imageImported", [Self.imageJSON(attachment), inline])
            } catch { call("error", [error.localizedDescription]) }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }

    var qaEditor: WKWebView { web }
}

/// A window-sized input shield. The document stays in screen coordinates even
/// when its source board is zoomed or the canvas is moved behind it.
@MainActor
private final class BoardTaskModalView: NSView {
    var onDismiss: (() -> Void)?
    private let shell = NSView()
    private let editor: WKWebView
    init(editor: WKWebView) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.48).cgColor
        shell.wantsLayer = true
        shell.layer?.cornerRadius = 14
        shell.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        shell.shadow = NSShadow()
        shell.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shell.shadow?.shadowBlurRadius = 32
        shell.shadow?.shadowOffset = NSSize(width: 0, height: -12)
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 14
        editor.layer?.masksToBounds = true
        addSubview(shell)
        shell.addSubview(editor)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Task details dialog")
    }
    required init?(coder: NSCoder) { fatalError() }
    func revealEditor() {
        editor.isHidden = false
        editor.needsDisplay = true
    }
    override func layout() {
        super.layout()
        let width = max(0, min(960, bounds.width - 48))
        let height = max(0, min(720, bounds.height - 48))
        shell.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        editor.frame = shell.bounds
    }
    override func mouseDown(with event: NSEvent) {
        if !shell.frame.contains(convert(event.locationInWindow, from: nil)) { onDismiss?() }
    }
    // Never bubble backdrop input into canvas navigation.
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
}

@MainActor
private final class BoardTaskImageScheme: NSObject, WKURLSchemeHandler {
    let store: BoardAttachmentStore?
    let boardID: UUID
    var attachments: [UUID: BoardAttachment] = [:]
    init(store: BoardAttachmentStore?, boardID: UUID) { self.store = store; self.boardID = boardID }
    private let thumbnails = ComposerImageIOThumbnailPipeline()
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let host = url.host, let id = UUID(uuidString: host), attachments[id] != nil, let store else {
            urlSchemeTask.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)); return
        }
        let key = ObjectIdentifier(urlSchemeTask)
        let file = store.fileURL(boardID: boardID, attachmentID: id)
        requests[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { requests[key] = nil }
            do {
                let thumbnail = try await thumbnails.thumbnail(for: file, maxPixelSize: 1024)
                guard !Task.isCancelled else { return }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: thumbnail.pngData.count, textEncodingName: nil))
                urlSchemeTask.didReceive(thumbnail.pngData); urlSchemeTask.didFinish()
            } catch { if !Task.isCancelled { urlSchemeTask.didFailWithError(error) } }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
