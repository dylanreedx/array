import AppKit
import ContinuumRevivedCore
import Foundation
import WebKit

@MainActor
protocol BrowserUIDialogPresenting: AnyObject {
    func presentJavaScriptAlert(message: String, window: NSWindow?, completion: @escaping () -> Void)
    func presentJavaScriptConfirm(message: String, window: NSWindow?, completion: @escaping (Bool) -> Void)
    func presentJavaScriptPrompt(prompt: String, defaultText: String?, window: NSWindow?, completion: @escaping (String?) -> Void)
    func presentOpenPanel(allowsMultipleSelection: Bool, allowsDirectories: Bool, window: NSWindow?, completion: @escaping ([URL]?) -> Void)
    func presentDownloadSavePanel(suggestedFilename: String, window: NSWindow?, completion: @escaping (URL?) -> Void)
}

@MainActor
final class AppKitBrowserUIDialogPresenter: BrowserUIDialogPresenting {
    func presentJavaScriptAlert(message: String, window: NSWindow?, completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        run(alert: alert, window: window) { _ in completion() }
    }

    func presentJavaScriptConfirm(message: String, window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        run(alert: alert, window: window) { response in completion(response == .alertFirstButtonReturn) }
    }

    func presentJavaScriptPrompt(prompt: String, defaultText: String?, window: NSWindow?, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        run(alert: alert, window: window) { response in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func presentOpenPanel(allowsMultipleSelection: Bool, allowsDirectories: Bool, window: NSWindow?, completion: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = allowsDirectories
        panel.canChooseFiles = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.urls : nil)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func presentDownloadSavePanel(suggestedFilename: String, window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.url : nil)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func run(alert: NSAlert, window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

@MainActor
final class WKWebViewBrowserRuntime: NSObject, BrowserRuntime {
    let id: BrowserRuntimeID
    let tileId: TileID

    private(set) var url: String
    private(set) var title: String
    private(set) var loadingState: BrowserLoadingState = .idle

    var onStateChange: (() -> Void)?

    /// Invoked when the WKWebView content process terminates unexpectedly.
    /// Fires at most once per runtime instance. Always called on MainActor.
    var onContentProcessTerminated: ((BrowserRuntimeID) -> Void)?

    private var didNotifyContentProcessTerminated = false
    private var isTerminated = false

    let webView: WKWebView
    private weak var hostView: BrowserHostView?
    private let uiDialogPresenter: BrowserUIDialogPresenting
    private var observers: [NSKeyValueObservation] = []
    private var activeDownloads: [ObjectIdentifier: WKDownload] = [:]
    var reservedShortcutHandler: ((NSEvent) -> Bool)? {
        didSet { hostView?.reservedShortcutHandler = reservedShortcutHandler }
    }

    init(
        id: BrowserRuntimeID = UUID(),
        tileId: TileID,
        webView: WKWebView,
        initialURL: String,
        uiDialogPresenter: BrowserUIDialogPresenting = AppKitBrowserUIDialogPresenter()
    ) {
        self.id = id
        self.tileId = tileId
        self.webView = webView
        self.uiDialogPresenter = uiDialogPresenter
        self.url = initialURL
        self.title = ""
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        installObservers()
    }

    private func installObservers() {
        // Each observer hops through Task { @MainActor in ... } so reads of
        // main-isolated WKWebView properties happen on main. The outer KVO
        // closure only captures `self` (weakly) — it never touches WKWebView
        // properties directly, which keeps Swift 6 strict concurrency happy.
        observers.append(webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.title = self.webView.title ?? ""
                self.onStateChange?()
            }
        })
        observers.append(webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                if let next = self.webView.url?.absoluteString, !next.isEmpty {
                    self.url = next
                    self.onStateChange?()
                }
            }
        })
        observers.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                if self.webView.isLoading {
                    self.loadingState = .loading(progress: self.webView.estimatedProgress)
                    self.onStateChange?()
                }
            }
        })
        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.webView.isLoading, case .loading = self.loadingState, self.activeDownloads.isEmpty {
                    self.loadingState = .idle
                    self.onStateChange?()
                }
            }
        })
    }

    func attach(to hostView: BrowserHostView) {
        self.hostView = hostView
        hostView.reservedShortcutHandler = reservedShortcutHandler
        webView.translatesAutoresizingMaskIntoConstraints = false
        hostView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: hostView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])
    }

    func detach() {
        webView.removeFromSuperview()
        hostView = nil
    }

    func loadURL(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            loadingState = .failed(message: "Invalid URL: \(urlString)")
            onStateChange?()
            return
        }
        self.url = urlString
        loadingState = .loading(progress: 0)
        onStateChange?()
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    func focus() {
        webView.window?.makeFirstResponder(webView)
    }

    func blur() {
        // WKWebView yields first responder when another view becomes key — no
        // explicit blur API. This is intentionally a no-op.
    }

    func isSemanticContentResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder === webView { return true }
        guard let responderView = responder as? NSView else { return false }
        var view: NSView? = responderView
        while let current = view {
            if current === webView { return true }
            view = current.superview
        }
        return false
    }

    func terminate(policy: TerminationPolicy) {
        // Order matters: stop loads, drop observers, drop delegates, remove view.
        // Inverting the order risks KVO/delegate callbacks firing into a
        // half-torn-down runtime.
        isTerminated = true
        webView.stopLoading()
        cancelActiveDownloads()
        observers.forEach { $0.invalidate() }
        observers.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        hostView = nil
        onStateChange = nil
    }
}

extension WKWebViewBrowserRuntime: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.loadingState = .idle
            self.onStateChange?()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.loadingState = .failed(message: message)
            self.onStateChange?()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.loadingState = .failed(message: message)
            self.onStateChange?()
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            guard !self.didNotifyContentProcessTerminated else { return }
            self.didNotifyContentProcessTerminated = true
            self.loadingState = .failed(message: "Web content process terminated")
            self.onStateChange?()
            self.onContentProcessTerminated?(self.id)
        }
    }

    @available(macOS 11.3, *)
    nonisolated func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        MainActor.assumeIsolated { self.beginDownload(download) }
    }

    @available(macOS 11.3, *)
    nonisolated func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        MainActor.assumeIsolated { self.beginDownload(download) }
    }

    @available(macOS 11.3, *)
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        Task { @MainActor in
            if navigationResponse.response.suggestedFilename != nil, !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

@available(macOS 11.3, *)
extension WKWebViewBrowserRuntime: WKDownloadDelegate {
    func beginDownload(_ download: WKDownload) {
        guard !isTerminated else { return }
        activeDownloads[ObjectIdentifier(download)] = download
        download.delegate = self
        loadingState = .loading(progress: 0)
        onStateChange?()
    }

    func webView(_ webView: WKWebView, start download: WKDownload) {
        beginDownload(download)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        handleDownloadDestination(suggestedFilename: suggestedFilename, completion: completionHandler)
    }

    func downloadDidFinish(_ download: WKDownload) {
        activeDownloads.removeValue(forKey: ObjectIdentifier(download))
        loadingState = activeDownloads.isEmpty ? .idle : .loading(progress: 0)
        onStateChange?()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.removeValue(forKey: ObjectIdentifier(download))
        loadingState = .failed(message: error.localizedDescription)
        onStateChange?()
    }
}

extension WKWebViewBrowserRuntime {
    func cancelActiveDownloads() {
        if #available(macOS 11.3, *) {
            for download in activeDownloads.values {
                download.cancel { _ in }
                download.delegate = nil
            }
        }
        activeDownloads.removeAll()
    }

    func handleDownloadDestination(suggestedFilename: String, completion: @escaping (URL?) -> Void) {
        uiDialogPresenter.presentDownloadSavePanel(suggestedFilename: Self.sanitizedDownloadFilename(suggestedFilename), window: dialogWindow) { url in
            completion(url)
        }
    }

    static func sanitizedDownloadFilename(_ suggestedFilename: String) -> String {
        let trimmed = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let sanitized = trimmed.components(separatedBy: invalid).filter { !$0.isEmpty }.joined(separator: "-")
        return sanitized.isEmpty ? "download" : sanitized
    }
}

extension WKWebViewBrowserRuntime: WKUIDelegate {
    private var dialogWindow: NSWindow? { webView.window ?? hostView?.window }

    func handleJavaScriptAlert(message: String, completion: @escaping () -> Void) {
        uiDialogPresenter.presentJavaScriptAlert(message: message, window: dialogWindow, completion: completion)
    }

    func handleJavaScriptConfirm(message: String, completion: @escaping (Bool) -> Void) {
        uiDialogPresenter.presentJavaScriptConfirm(message: message, window: dialogWindow, completion: completion)
    }

    func handleJavaScriptPrompt(prompt: String, defaultText: String?, completion: @escaping (String?) -> Void) {
        uiDialogPresenter.presentJavaScriptPrompt(prompt: prompt, defaultText: defaultText, window: dialogWindow, completion: completion)
    }

    func handleOpenPanel(allowsMultipleSelection: Bool, allowsDirectories: Bool, completion: @escaping ([URL]?) -> Void) {
        uiDialogPresenter.presentOpenPanel(
            allowsMultipleSelection: allowsMultipleSelection,
            allowsDirectories: allowsDirectories,
            window: dialogWindow,
            completion: completion
        )
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        handleJavaScriptAlert(message: message, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        handleJavaScriptConfirm(message: message, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        handleJavaScriptPrompt(prompt: prompt, defaultText: defaultText, completion: completionHandler)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        handleOpenPanel(
            allowsMultipleSelection: parameters.allowsMultipleSelection,
            allowsDirectories: parameters.allowsDirectories,
            completion: completionHandler
        )
    }
}

extension WKWebViewBrowserRuntime {
    static func runUIDelegateSelfCheck() throws {
        final class FakePresenter: BrowserUIDialogPresenting {
            struct Call: Equatable {
                var kind: String
                var message: String
                var windowMatched: Bool
                var allowsMultipleSelection: Bool
                var allowsDirectories: Bool
            }
            weak var expectedWindow: NSWindow?
            var calls: [Call] = []
            func presentJavaScriptAlert(message: String, window: NSWindow?, completion: @escaping () -> Void) {
                calls.append(Call(kind: "alert", message: message, windowMatched: window === expectedWindow, allowsMultipleSelection: false, allowsDirectories: false))
                completion()
            }
            func presentJavaScriptConfirm(message: String, window: NSWindow?, completion: @escaping (Bool) -> Void) {
                calls.append(Call(kind: "confirm", message: message, windowMatched: window === expectedWindow, allowsMultipleSelection: false, allowsDirectories: false))
                completion(false)
            }
            func presentJavaScriptPrompt(prompt: String, defaultText: String?, window: NSWindow?, completion: @escaping (String?) -> Void) {
                calls.append(Call(kind: "prompt", message: "\(prompt)|\(defaultText ?? "")", windowMatched: window === expectedWindow, allowsMultipleSelection: false, allowsDirectories: false))
                completion("typed")
            }
            func presentOpenPanel(allowsMultipleSelection: Bool, allowsDirectories: Bool, window: NSWindow?, completion: @escaping ([URL]?) -> Void) {
                calls.append(Call(kind: "open", message: "", windowMatched: window === expectedWindow, allowsMultipleSelection: allowsMultipleSelection, allowsDirectories: allowsDirectories))
                completion([URL(fileURLWithPath: "/tmp/continuum-upload.txt")])
            }
            var downloadDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            func presentDownloadSavePanel(suggestedFilename: String, window: NSWindow?, completion: @escaping (URL?) -> Void) {
                calls.append(Call(kind: "download", message: suggestedFilename, windowMatched: window === expectedWindow, allowsMultipleSelection: false, allowsDirectories: false))
                completion(downloadDirectory.appendingPathComponent(suggestedFilename))
            }
        }

        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { if case let .failed(message) = self { return message }; return "failed" }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fake = FakePresenter()
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let runtime = WKWebViewBrowserRuntime(tileId: TileID(), webView: webView, initialURL: "about:blank", uiDialogPresenter: fake)
        let host = BrowserHostView()
        runtime.attach(to: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        fake.expectedWindow = window
        window.makeKeyAndOrderFront(nil)
        defer {
            runtime.terminate(policy: .requestClose)
            window.close()
        }

        var alertCompleted = false
        runtime.handleJavaScriptAlert(message: "hello") { alertCompleted = true }
        try expect(alertCompleted, "alert completion should be called")

        var confirmValue: Bool?
        runtime.handleJavaScriptConfirm(message: "continue?") { confirmValue = $0 }
        try expect(confirmValue == false, "confirm should forward presenter's default-button/cancel result")

        var promptValue: String?
        runtime.handleJavaScriptPrompt(prompt: "name", defaultText: "Dylan") { promptValue = $0 }
        try expect(promptValue == "typed", "prompt should forward presenter text result")

        var urls: [URL]?
        runtime.handleOpenPanel(allowsMultipleSelection: true, allowsDirectories: true) { urls = $0 }
        try expect(urls?.map(\.lastPathComponent) == ["continuum-upload.txt"], "open panel should forward selected URLs")

        var downloadURL: URL?
        runtime.handleDownloadDestination(suggestedFilename: "reports/quarterly:one.txt") { downloadURL = $0 }
        try expect(downloadURL?.lastPathComponent == "reports-quarterly-one.txt", "download destination handler should receive a safe suggested filename")
        try expect(Self.sanitizedDownloadFilename("/:") == "download", "download filename sanitizer should fall back when stripping invalid characters empties the name")

        try expect(fake.calls == [
            .init(kind: "alert", message: "hello", windowMatched: true, allowsMultipleSelection: false, allowsDirectories: false),
            .init(kind: "confirm", message: "continue?", windowMatched: true, allowsMultipleSelection: false, allowsDirectories: false),
            .init(kind: "prompt", message: "name|Dylan", windowMatched: true, allowsMultipleSelection: false, allowsDirectories: false),
            .init(kind: "open", message: "", windowMatched: true, allowsMultipleSelection: true, allowsDirectories: true),
            .init(kind: "download", message: "reports-quarterly-one.txt", windowMatched: true, allowsMultipleSelection: false, allowsDirectories: false)
        ], "delegate calls should preserve kind, payload, window anchor, and open-panel/download flags")

        fake.calls.removeAll()
        fake.downloadDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("continuum-download-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fake.downloadDirectory, withIntermediateDirectories: true)
        let html = """
        <html><body><a id='download' download='fixture.txt' href='data:text/plain;charset=utf-8,continuum-download-check'>download</a></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        let loadDeadline = Date().addingTimeInterval(5)
        while webView.isLoading && Date() < loadDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        webView.evaluateJavaScript("document.getElementById('download').click()")
        let downloadDeadline = Date().addingTimeInterval(5)
        while Date() < downloadDeadline {
            if fake.calls.contains(where: { $0.kind == "download" && $0.message == "fixture.txt" }) { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        try expect(fake.calls.contains(where: { $0.kind == "download" && $0.message == "fixture.txt" && $0.windowMatched }), "actual WKWebView download click should request a save destination through the presenter")
    }
}
