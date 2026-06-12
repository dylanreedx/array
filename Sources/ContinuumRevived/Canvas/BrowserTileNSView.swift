import AppKit
import ContinuumRevivedCore
import Foundation
import WebKit

/// Tile view that hosts a live `WKWebView` runtime. Composes a nav row
/// (back / forward / reload + URL bar + spinner) above a `BrowserHostView`.
/// Subscribes to the runtime's `onStateChange` to refresh URL/loading/error
/// state. Title-bar drag and perimeter resize from `TileNSView` continue
/// to work — clicks land inside the content view's subviews (buttons,
/// URL field, web view) before reaching `TileNSView.mouseDown`.
@MainActor
final class BrowserTileNSView: TileNSView, NSTextFieldDelegate {
    let hostView: BrowserHostView
    let runtime: any BrowserRuntime

    /// Fires after every state-driven `refresh()`. Spawner sets this to the
    /// debounced persistence handler so URL/title changes flow into BrowserState.
    var onAfterRefresh: (() -> Void)?

    private let urlField: NSTextField
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let reloadButton: NSButton
    private let progressIndicator: NSProgressIndicator
    private let errorBanner: NSTextField

    init(tile: Tile, runtime: any BrowserRuntime) {
        self.runtime = runtime
        self.hostView = BrowserHostView(frame: .zero)
        self.urlField = NSTextField()
        self.backButton = NSButton(title: "‹", target: nil, action: nil)
        self.forwardButton = NSButton(title: "›", target: nil, action: nil)
        self.reloadButton = NSButton(title: "↻", target: nil, action: nil)
        self.progressIndicator = NSProgressIndicator()
        self.errorBanner = NSTextField(labelWithString: "")
        super.init(tile: tile)

        let body = NSView()
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1.0).cgColor

        backButton.target = self
        backButton.action = #selector(handleBack(_:))
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false

        forwardButton.target = self
        forwardButton.action = #selector(handleForward(_:))
        forwardButton.bezelStyle = .rounded
        forwardButton.translatesAutoresizingMaskIntoConstraints = false

        reloadButton.target = self
        reloadButton.action = #selector(handleReload(_:))
        reloadButton.bezelStyle = .rounded
        reloadButton.translatesAutoresizingMaskIntoConstraints = false

        urlField.delegate = self
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.placeholderString = "URL"
        urlField.stringValue = runtime.url
        urlField.focusRingType = .none
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        let navRow = NSStackView(views: [backButton, forwardButton, reloadButton, urlField, progressIndicator])
        navRow.orientation = .horizontal
        navRow.spacing = 4
        navRow.alignment = .centerY
        navRow.distribution = .fill
        navRow.translatesAutoresizingMaskIntoConstraints = false

        errorBanner.font = .systemFont(ofSize: 11)
        errorBanner.textColor = .systemRed
        errorBanner.maximumNumberOfLines = 2
        errorBanner.lineBreakMode = .byTruncatingTail
        errorBanner.isHidden = true
        errorBanner.translatesAutoresizingMaskIntoConstraints = false

        hostView.translatesAutoresizingMaskIntoConstraints = false

        body.addSubview(navRow)
        body.addSubview(errorBanner)
        body.addSubview(hostView)

        NSLayoutConstraint.activate([
            navRow.topAnchor.constraint(equalTo: body.topAnchor, constant: 4),
            navRow.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 6),
            navRow.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -6),
            navRow.heightAnchor.constraint(equalToConstant: 24),

            errorBanner.topAnchor.constraint(equalTo: navRow.bottomAnchor, constant: 2),
            errorBanner.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 8),
            errorBanner.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8),

            hostView.topAnchor.constraint(equalTo: errorBanner.bottomAnchor, constant: 4),
            hostView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            hostView.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])

        setContentView(body)

        hostView.attach(runtime: runtime)

        runtime.onStateChange = { [weak self] in
            self?.refresh()
            self?.onAfterRefresh?()
        }
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        runtime.focus()
        return true
    }

    override func releaseFocus(reason: FocusRequest) {
        runtime.blur()
    }

    private func refresh() {
        // Don't clobber a URL the user is actively typing.
        if urlField.currentEditor() == nil {
            urlField.stringValue = runtime.url
        }
        switch runtime.loadingState {
        case .idle:
            progressIndicator.stopAnimation(nil)
            errorBanner.isHidden = true
            errorBanner.stringValue = ""
        case .loading:
            progressIndicator.startAnimation(nil)
            errorBanner.isHidden = true
        case let .failed(message):
            progressIndicator.stopAnimation(nil)
            errorBanner.stringValue = message
            errorBanner.isHidden = false
        }
    }

    @objc private func handleBack(_ sender: Any?) { runtime.goBack() }
    @objc private func handleForward(_ sender: Any?) { runtime.goForward() }
    @objc private func handleReload(_ sender: Any?) { runtime.reload() }

    private func focusBrowserContent() {
        runtime.focus()
    }

    var browserContentHasFocusForQA: Bool {
        runtime.isSemanticContentResponder(window?.firstResponder)
    }

    var chromeURLStringForQA: String { urlField.stringValue }

    @discardableResult
    func performURLFieldCommandForQA(_ commandSelector: Selector) -> Bool {
        window?.makeFirstResponder(urlField)
        return control(urlField, textView: NSTextView(), doCommandBy: commandSelector)
    }

    static func runURLFocusSelfCheck() throws {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let dataPage = "data:text/html,<html><body><input id='qa' autofocus value='ready'></body></html>"
        let tileId = TileID()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let runtime = WKWebViewBrowserRuntime(tileId: tileId, webView: webView, initialURL: dataPage)
        let tile = Tile(
            id: tileId,
            kind: .browser,
            title: "Browser",
            frame: TileFrame(x: 0, y: 0, width: 640, height: 420),
            zIndex: 0,
            runtimeRef: nil,
            metadata: TileMetadata(url: runtime.url)
        )
        let browserTile = BrowserTileNSView(tile: tile, runtime: runtime)
        browserTile.frame = NSRect(x: 0, y: 0, width: 640, height: 420)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = browserTile
        window.makeKeyAndOrderFront(nil)
        defer {
            runtime.terminate(policy: .requestClose)
            window.close()
        }

        browserTile.urlField.stringValue = dataPage
        try expect(
            browserTile.performURLFieldCommandForQA(#selector(NSResponder.insertNewline(_:))),
            "Return command should be handled"
        )
        try expect(runtime.url == dataPage, "Return should load typed data: URL through real WKWebView runtime")
        try expect(runtime.isSemanticContentResponder(window.firstResponder), "Return should leave real WKWebView content focused")
        try expect(window.firstResponder !== browserTile.hostView, "Return must not focus plain BrowserHostView")
        try expect(webView === window.firstResponder || runtime.isSemanticContentResponder(window.firstResponder), "Return first responder must be WKWebView or descendant")

        browserTile.urlField.stringValue = "https://example.test/dirty"
        try expect(
            browserTile.performURLFieldCommandForQA(#selector(NSResponder.cancelOperation(_:))),
            "Escape command should be handled"
        )
        try expect(browserTile.urlField.stringValue == runtime.url, "Escape should restore runtime URL")
        try expect(runtime.isSemanticContentResponder(window.firstResponder), "Escape should leave real WKWebView content focused")
        try expect(window.firstResponder !== browserTile.hostView, "Escape must not focus plain BrowserHostView")
        try expect(webView === window.firstResponder || runtime.isSemanticContentResponder(window.firstResponder), "Escape first responder must be WKWebView or descendant")
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let next = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !next.isEmpty {
                runtime.loadURL(next)
            }
            focusBrowserContent()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            urlField.stringValue = runtime.url
            focusBrowserContent()
            return true
        default:
            return false
        }
    }
}
