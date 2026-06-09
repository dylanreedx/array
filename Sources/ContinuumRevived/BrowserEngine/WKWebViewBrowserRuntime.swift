import AppKit
import ContinuumRevivedCore
import Foundation
import WebKit

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
    private var observers: [NSKeyValueObservation] = []

    init(
        id: BrowserRuntimeID = UUID(),
        tileId: TileID,
        webView: WKWebView,
        initialURL: String
    ) {
        self.id = id
        self.tileId = tileId
        self.webView = webView
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
    // Default WKUIDelegate behavior is sufficient for Phase 5 — no JS alerts /
    // confirms / file pickers / new-window UX yet.
}
