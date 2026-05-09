import AppKit
import ContinuumRevivedCore
import Foundation

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

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let next = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !next.isEmpty {
                runtime.loadURL(next)
            }
            window?.makeFirstResponder(hostView)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            urlField.stringValue = runtime.url
            window?.makeFirstResponder(hostView)
            return true
        default:
            return false
        }
    }
}
