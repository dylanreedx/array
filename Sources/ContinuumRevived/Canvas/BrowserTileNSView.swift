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

    var browserProfilesProvider: (() -> [BrowserProfile])?
    var activeBrowserProfileProvider: (() -> UUID)?
    var onSwitchBrowserProfile: ((UUID) -> Void)?
    var onCreateBrowserProfile: (() -> Void)?
    var onRenameBrowserProfile: ((UUID) -> Void)?
    var onDeleteBrowserProfile: ((UUID) -> Void)?

    private let urlField: NSTextField
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let reloadButton: NSButton
    private let profileMenuButton: NSButton
    private let faviconLabel: NSTextField
    private let progressIndicator: NSProgressIndicator
    private let errorBanner: NSTextField
    private var lastPersistedURL: String
    private var lastPersistedTitle: String

    init(tile: Tile, runtime: any BrowserRuntime) {
        self.runtime = runtime
        self.hostView = BrowserHostView(frame: .zero)
        self.urlField = NSTextField()
        self.backButton = NSButton(title: "‹", target: nil, action: nil)
        self.forwardButton = NSButton(title: "›", target: nil, action: nil)
        self.reloadButton = NSButton(title: "↻", target: nil, action: nil)
        self.profileMenuButton = NSButton(title: "⋯", target: nil, action: nil)
        self.faviconLabel = NSTextField(labelWithString: "◌")
        self.progressIndicator = NSProgressIndicator()
        self.errorBanner = NSTextField(labelWithString: "")
        self.lastPersistedURL = runtime.url
        self.lastPersistedTitle = runtime.title
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

        profileMenuButton.target = self
        profileMenuButton.action = #selector(showProfileMenu(_:))
        profileMenuButton.bezelStyle = .rounded
        profileMenuButton.toolTip = "Browser profiles"
        profileMenuButton.translatesAutoresizingMaskIntoConstraints = false

        urlField.delegate = self
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.placeholderString = "URL"
        urlField.stringValue = runtime.url
        urlField.focusRingType = .none
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        faviconLabel.translatesAutoresizingMaskIntoConstraints = false
        faviconLabel.font = .systemFont(ofSize: 13)
        faviconLabel.textColor = .secondaryLabelColor
        faviconLabel.toolTip = "Page icon"

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.isIndeterminate = false
        progressIndicator.isDisplayedWhenStopped = false

        let navRow = NSStackView(views: [backButton, forwardButton, reloadButton, faviconLabel, urlField, progressIndicator, profileMenuButton])
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
            guard let self else { return }
            self.refresh()
            if self.lastPersistedURL != self.runtime.url || self.lastPersistedTitle != self.runtime.title {
                self.lastPersistedURL = self.runtime.url
                self.lastPersistedTitle = self.runtime.title
                self.onAfterRefresh?()
            }
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
        let displayTitle = runtime.title.isEmpty ? tile.title : runtime.title
        if tile.title != displayTitle {
            tile.title = displayTitle
            sync(tile: tile)
        }
        faviconLabel.stringValue = runtime.faviconURL == nil ? "◌" : "●"
        faviconLabel.toolTip = runtime.faviconURL ?? "No page icon detected"
        switch runtime.loadingState {
        case .idle:
            progressIndicator.doubleValue = 0
            progressIndicator.isHidden = true
            errorBanner.isHidden = true
            errorBanner.stringValue = ""
        case let .loading(progress):
            progressIndicator.doubleValue = min(max(progress, 0), 1)
            progressIndicator.isHidden = false
            errorBanner.isHidden = true
        case let .failed(message):
            progressIndicator.doubleValue = 0
            progressIndicator.isHidden = true
            errorBanner.stringValue = message
            errorBanner.isHidden = false
        }
    }

    @objc private func handleBack(_ sender: Any?) { runtime.goBack() }
    @objc private func handleForward(_ sender: Any?) { runtime.goForward() }
    @objc private func handleReload(_ sender: Any?) { runtime.reload() }

    @objc private func showProfileMenu(_ sender: NSButton) {
        profileMenuForQA().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    func profileMenuForQA() -> NSMenu {
        let profiles = browserProfilesProvider?() ?? [BrowserProfile.builtInDefault()]
        let activeId = activeBrowserProfileProvider?() ?? BrowserProfile.defaultProfileId
        let menu = NSMenu()
        for profile in profiles.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let item = NSMenuItem(title: profile.name, action: #selector(selectBrowserProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == activeId ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let create = NSMenuItem(title: "Create Profile…", action: #selector(createBrowserProfile(_:)), keyEquivalent: "")
        create.target = self
        menu.addItem(create)
        if activeId != BrowserProfile.defaultProfileId {
            let rename = NSMenuItem(title: "Rename Current Profile…", action: #selector(renameBrowserProfile(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = activeId
            menu.addItem(rename)
            let delete = NSMenuItem(title: "Delete Current Profile…", action: #selector(deleteBrowserProfile(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = activeId
            menu.addItem(delete)
        }
        return menu
    }

    @objc private func selectBrowserProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onSwitchBrowserProfile?(id)
    }

    @objc private func createBrowserProfile(_ sender: NSMenuItem) { onCreateBrowserProfile?() }

    @objc private func renameBrowserProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onRenameBrowserProfile?(id)
    }

    @objc private func deleteBrowserProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onDeleteBrowserProfile?(id)
    }

    private func focusBrowserContent() {
        runtime.focus()
    }

    var browserContentHasFocusForQA: Bool {
        runtime.isSemanticContentResponder(window?.firstResponder)
    }

    var chromeURLStringForQA: String { urlField.stringValue }
    var chromeTitleForQA: String { chromeSnapshot?.title ?? "" }
    var chromeFaviconTooltipForQA: String? { faviconLabel.toolTip }
    var chromeProgressForQA: (hidden: Bool, value: Double) { (progressIndicator.isHidden, progressIndicator.doubleValue) }

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

        func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return condition()
        }

        let dataPage = "data:text/html,<html><head><title>continuum-browser-polish</title><link rel='icon' href='data:image/png;base64,iVBORw0KGgo='></head><body><input id='qa' autofocus value='ready'></body></html>"
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

        let customProfile = BrowserProfile(id: UUID(), name: "QA Custom", dataStoreIdentifier: UUID().uuidString, createdAt: Date())
        var activeProfileId = customProfile.id
        var switchedProfileId: UUID?
        var createRequested = false
        var renamedProfileId: UUID?
        var deletedProfileId: UUID?
        browserTile.browserProfilesProvider = { [BrowserProfile.builtInDefault(), customProfile] }
        browserTile.activeBrowserProfileProvider = { activeProfileId }
        browserTile.onSwitchBrowserProfile = { switchedProfileId = $0; activeProfileId = $0 }
        browserTile.onCreateBrowserProfile = { createRequested = true }
        browserTile.onRenameBrowserProfile = { renamedProfileId = $0 }
        browserTile.onDeleteBrowserProfile = { deletedProfileId = $0 }
        let profileMenu = browserTile.profileMenuForQA()
        try expect(profileMenu.items.contains(where: { $0.title == "QA Custom" && $0.state == .on }), "profile menu marks active custom profile")
        try expect(profileMenu.items.contains(where: { $0.title == "Default" }), "profile menu includes Default")
        try expect(profileMenu.items.contains(where: { $0.title == "Create Profile…" }), "profile menu includes create action")
        try expect(profileMenu.items.contains(where: { $0.title == "Rename Current Profile…" }), "profile menu includes rename action for custom active profile")
        try expect(profileMenu.items.contains(where: { $0.title == "Delete Current Profile…" }), "profile menu includes delete action for custom active profile")
        if let defaultItem = profileMenu.items.first(where: { $0.title == "Default" }) { browserTile.selectBrowserProfile(defaultItem) }
        try expect(switchedProfileId == BrowserProfile.defaultProfileId, "profile menu switch callback carries selected profile id")
        if let createItem = profileMenu.items.first(where: { $0.title == "Create Profile…" }) { browserTile.createBrowserProfile(createItem) }
        try expect(createRequested, "profile menu create callback fires")
        if let renameItem = profileMenu.items.first(where: { $0.title == "Rename Current Profile…" }) { browserTile.renameBrowserProfile(renameItem) }
        try expect(renamedProfileId == customProfile.id, "profile menu rename callback carries active custom profile id")
        if let deleteItem = profileMenu.items.first(where: { $0.title == "Delete Current Profile…" }) { browserTile.deleteBrowserProfile(deleteItem) }
        try expect(deletedProfileId == customProfile.id, "profile menu delete callback carries active custom profile id")

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
        try expect(browserTile.chromeProgressForQA.hidden == false, "loading progress should be visible immediately after navigation starts")
        try expect(waitUntil { runtime.title == "continuum-browser-polish" }, "runtime should observe page title")
        try expect(waitUntil { browserTile.chromeTitleForQA.contains("continuum-browser-polish") }, "browser chrome should mirror page title")
        try expect(waitUntil { browserTile.chromeFaviconTooltipForQA?.hasPrefix("data:image/png") == true }, "browser chrome should expose detected favicon URL")
        try expect(waitUntil { browserTile.chromeProgressForQA.hidden }, "loading progress should hide after navigation finishes")
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
