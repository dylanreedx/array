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

    let webView: WKWebView
    private weak var hostView: BrowserHostView?
    private let uiDialogPresenter: BrowserUIDialogPresenting
    private var observers: [NSKeyValueObservation] = []
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
                if !self.webView.isLoading, case .loading = self.loadingState {
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
        webView.stopLoading()
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

        try expect(fake.calls == [
            .init(kind: "alert", message: "hello", windowMatched: true, allowsMultipleSelection: false, allowsDirectories: false),
            .init(kind: "confirm", message: "continue?", windowMatched: true, allowsMultipleSelection: false, allowsDirectories: false),
            .init(kind: "prompt", message: "name|Dylan", windowMatched: true, allowsMultipleSelection: false, allowsDirectories: false),
            .init(kind: "open", message: "", windowMatched: true, allowsMultipleSelection: true, allowsDirectories: true)
        ], "delegate calls should preserve kind, payload, window anchor, and open-panel flags")
    }
}
