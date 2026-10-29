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
final class BrowserTileNSView: TileNSView, NSTextFieldDelegate, NSSearchFieldDelegate {
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
    var onSignOutAgents: (() -> Void)?
    var onOpenInspector: (() -> Void)?

    private let urlField: NSTextField
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let reloadButton: NSButton
    private let profileMenuButton: ChoiceButton
    private let agentControlButton: ChoiceButton
    private(set) var agentControlTitleForQA: String?
    private var agentControlActions: [ChoiceItem] = []
    private var browserActivityLines: [String] = []
    var qaBrowserActivity: [String] { agentControlButton.items.filter { $0.id.hasPrefix("activity-") }.map(\.title) }
    private let faviconLabel: NSTextField
    private let progressIndicator: NSProgressIndicator
    private let findField: NSSearchField
    private let findResultLabel: NSTextField
    private let findPreviousButton: NSButton
    private let findNextButton: NSButton
    private let findCloseButton: NSButton
    private let findRow: NSStackView
    private let findRowHeightConstraint: NSLayoutConstraint
    private let errorBanner: NSTextField
    private let tabStrip: NSStackView
    private let newTabButton: NSButton
    private let closeTabButton: NSButton
    private var tabModel: BrowserTabModel
    private var tabButtonIds: [Int: UUID] = [:]
    private var tabStripRenderSignature: [String] = []
    private var lastPersistedURL: String
    private var lastPersistedTitle: String
    private(set) var lastTabActivationUsedInteractionStateForQA = false
    private(set) var lastInvalidTabURLFallbackForQA: String?

    /// Fires after tab create/switch/close or active-tab snapshot changes.
    var onTabModelChange: ((BrowserTabModel) -> Void)?

    init(tile: Tile, runtime: any BrowserRuntime, browserTile: BrowserTile? = nil) {
        self.runtime = runtime
        self.hostView = BrowserHostView(frame: .zero)
        self.urlField = NSTextField()
        self.backButton = NSButton(title: "‹", target: nil, action: nil)
        self.forwardButton = NSButton(title: "›", target: nil, action: nil)
        self.reloadButton = NSButton(title: "↻", target: nil, action: nil)
        self.profileMenuButton = ChoiceButton(title: "Default")
        self.agentControlButton = ChoiceButton(title: "Agent")
        self.faviconLabel = NSTextField(labelWithString: "◌")
        self.progressIndicator = NSProgressIndicator()
        self.findField = NSSearchField()
        self.findResultLabel = NSTextField(labelWithString: "")
        self.findPreviousButton = NSButton(title: "↑", target: nil, action: nil)
        self.findNextButton = NSButton(title: "↓", target: nil, action: nil)
        self.findCloseButton = NSButton(title: "×", target: nil, action: nil)
        self.findRow = NSStackView()
        self.findRowHeightConstraint = findRow.heightAnchor.constraint(equalToConstant: 0)
        self.errorBanner = NSTextField(labelWithString: "")
        self.tabStrip = NSStackView()
        self.newTabButton = NSButton(title: "+", target: nil, action: nil)
        self.closeTabButton = NSButton(title: "×", target: nil, action: nil)
        let now = Date()
        if let browserTile {
            self.tabModel = BrowserTabModel(tabs: browserTile.tabs, activeTabId: browserTile.activeTabId)
        } else {
            let tab = BrowserTab(url: runtime.url, title: runtime.title, createdAt: now, lastAccessedAt: now)
            self.tabModel = BrowserTabModel(tabs: [tab], activeTabId: tab.id)
        }
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

        profileMenuButton.keepsSelectionForItem = { UUID(uuidString: $0.id) == nil }
        profileMenuButton.onSelection = { [weak self] item in self?.chooseBrowserProfile(item) }
        profileMenuButton.toolTip = "Browser profiles"
        profileMenuButton.translatesAutoresizingMaskIntoConstraints = false

        agentControlButton.isHidden = true
        agentControlButton.popoverPresentation = .commands
        agentControlButton.keepsSelectionForItem = { _ in true }
        agentControlButton.toolTip = "Browser control"
        agentControlButton.translatesAutoresizingMaskIntoConstraints = false

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

        newTabButton.target = self
        newTabButton.action = #selector(handleNewTab(_:))
        newTabButton.bezelStyle = .rounded
        closeTabButton.target = self
        closeTabButton.action = #selector(handleCloseTab(_:))
        closeTabButton.bezelStyle = .rounded
        tabStrip.orientation = .horizontal
        tabStrip.spacing = 4
        tabStrip.alignment = .centerY
        tabStrip.distribution = .fill
        tabStrip.translatesAutoresizingMaskIntoConstraints = false

        let navRow = NSStackView(views: [backButton, forwardButton, reloadButton, faviconLabel, urlField, progressIndicator, agentControlButton, profileMenuButton])
        navRow.orientation = .horizontal
        navRow.spacing = 4
        navRow.alignment = .centerY
        navRow.distribution = .fill
        navRow.translatesAutoresizingMaskIntoConstraints = false

        findField.delegate = self
        findField.placeholderString = "Find in page"
        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.focusRingType = .none
        findField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        findField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Shows "No matches" when a find returns no result; cleared on a match,
        // an emptied query, or when the bar hides. WebKit's WKFindResult has no
        // public count, so this is found/not-found only — no "N of M" (deferred).
        findResultLabel.font = .systemFont(ofSize: 11)
        findResultLabel.textColor = .secondaryLabelColor
        findResultLabel.translatesAutoresizingMaskIntoConstraints = false
        findResultLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        findResultLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        findPreviousButton.target = self
        findPreviousButton.action = #selector(handleFindPrevious(_:))
        findPreviousButton.bezelStyle = .rounded
        findPreviousButton.toolTip = "Previous match"
        findPreviousButton.translatesAutoresizingMaskIntoConstraints = false

        findNextButton.target = self
        findNextButton.action = #selector(handleFindNext(_:))
        findNextButton.bezelStyle = .rounded
        findNextButton.toolTip = "Next match"
        findNextButton.translatesAutoresizingMaskIntoConstraints = false

        findCloseButton.target = self
        findCloseButton.action = #selector(handleFindClose(_:))
        findCloseButton.bezelStyle = .rounded
        findCloseButton.toolTip = "Close find"
        findCloseButton.translatesAutoresizingMaskIntoConstraints = false

        findRow.setViews([findField, findResultLabel, findPreviousButton, findNextButton, findCloseButton], in: .leading)
        findRow.orientation = .horizontal
        findRow.spacing = 4
        findRow.alignment = .centerY
        findRow.distribution = .fill
        findRow.isHidden = true
        findRow.translatesAutoresizingMaskIntoConstraints = false

        errorBanner.font = .systemFont(ofSize: 11)
        errorBanner.textColor = .systemRed
        errorBanner.maximumNumberOfLines = 2
        errorBanner.lineBreakMode = .byTruncatingTail
        errorBanner.isHidden = true
        errorBanner.translatesAutoresizingMaskIntoConstraints = false

        hostView.translatesAutoresizingMaskIntoConstraints = false

        body.addSubview(tabStrip)
        body.addSubview(navRow)
        body.addSubview(findRow)
        body.addSubview(errorBanner)
        body.addSubview(hostView)

        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: body.topAnchor, constant: 4),
            tabStrip.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 6),
            tabStrip.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -6),
            tabStrip.heightAnchor.constraint(equalToConstant: 24),

            navRow.topAnchor.constraint(equalTo: tabStrip.bottomAnchor, constant: 4),
            navRow.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 6),
            navRow.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -6),
            navRow.heightAnchor.constraint(equalToConstant: 24),

            findRow.topAnchor.constraint(equalTo: navRow.bottomAnchor, constant: 4),
            findRow.leadingAnchor.constraint(greaterThanOrEqualTo: body.leadingAnchor, constant: 6),
            findRow.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -6),
            findRow.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            findRowHeightConstraint,

            errorBanner.topAnchor.constraint(equalTo: findRow.bottomAnchor, constant: 2),
            errorBanner.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 8),
            errorBanner.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8),

            hostView.topAnchor.constraint(equalTo: errorBanner.bottomAnchor, constant: 4),
            hostView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            hostView.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])

        setContentView(body)

        hostView.attach(runtime: runtime)
        hostView.browserFindShortcutHandler = { [weak self] in
            self?.showFindBar()
            return self != nil
        }

        runtime.onStateChange = { [weak self] in
            guard let self else { return }
            self.snapshotActiveTabFromRuntime()
            self.refresh()
            if self.lastPersistedURL != self.runtime.url || self.lastPersistedTitle != self.runtime.title {
                self.lastPersistedURL = self.runtime.url
                self.lastPersistedTitle = self.runtime.title
                self.onAfterRefresh?()
            }
        }
        runtime.onFindResult = { [weak self] matchFound in
            self?.showFindResult(matchFound: matchFound)
        }
        refresh()
        rebuildTabStrip()
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

    override func canHandleReservedShortcut(_ shortcut: ReservedShortcut) -> Bool {
        shortcut == .focusMode
    }

    override func makeAdditionalTitleBarMenuItems() -> [NSMenuItem] {
        let openInspector = NSMenuItem(title: "Open Inspector Tile", action: #selector(openInspectorFromMenu(_:)), keyEquivalent: "")
        openInspector.target = self
        return [openInspector]
    }

    func contextMenuForQA() -> NSMenu {
        titleBarContextMenuForQA()
    }

    @objc private func openInspectorFromMenu(_ sender: Any?) {
        onOpenInspector?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 3, flags == .command {
            showFindBar()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func snapshotActiveTabFromRuntime() {
        let current = tabModel.activeTab
        let snapshotTitle = runtime.title.isEmpty ? current.title : runtime.title
        let snapshotInteractionState: Data?
        if case .loading = runtime.loadingState, runtime.url == current.url {
            // WKWebView can still expose the previous document's interactionState
            // during the synchronous load-start callback. Keep the tab's current
            // snapshot while the destination is loading; the finished/idle state
            // change captures the new page state when WebKit has one.
            snapshotInteractionState = current.interactionState
        } else {
            snapshotInteractionState = runtime.capturedInteractionState
        }
        let changed = current.url != runtime.url
            || current.title != snapshotTitle
            || current.faviconURL != runtime.faviconURL
            || current.interactionState != snapshotInteractionState
        guard changed else { return }
        tabModel.updateActiveTab(url: runtime.url, title: snapshotTitle, faviconURL: runtime.faviconURL, interactionState: snapshotInteractionState)
        onTabModelChange?(tabModel)
    }

    /// What an address typed into the bar means, as browsers read it. A URL with a real scheme stays
    /// as typed ("https://…", "file:///…", "about:blank", "data:…"). A bare host gets one: http for a
    /// local host (localhost, an IP, `*.local`, or a dotless host with a port, the way a dev server is
    /// typed: "localhost:3000"), https otherwise ("example.com/docs"). nil when it is not an address.
    /// Without this, "localhost:3000" parsed as the scheme "localhost" and loaded nothing, and
    /// "example.com" had no scheme at all and fell back to about:blank.
    static func addressBarDestination(_ typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let scheme = URL(string: text)?.scheme?.lowercased(),
           text.contains("://") || ["about", "data", "blob", "mailto"].contains(scheme) {
            return text
        }
        guard !text.contains(where: \.isWhitespace), let url = URL(string: "http://" + text), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let ip = host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
        let local = host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || ip
            || (!host.contains(".") && url.port != nil)
        guard local || host.contains(".") else { return nil }
        return (local ? "http://" : "https://") + text
    }

    private static func isLoadableBrowserURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return !(url.scheme ?? "").isEmpty
    }

    private func activeTabPreparedForNavigation() -> BrowserTab {
        let active = tabModel.activeTab
        guard Self.isLoadableBrowserURL(active.url) else {
            lastInvalidTabURLFallbackForQA = active.url
            tabModel.updateActiveTab(url: DefaultBrowserURL.fallback, title: "", faviconURL: nil, interactionState: nil)
            onTabModelChange?(tabModel)
            return tabModel.activeTab
        }
        lastInvalidTabURLFallbackForQA = nil
        return active
    }

    private func loadOrRestoreActiveTab(focus: Bool = true) {
        let active = activeTabPreparedForNavigation()
        if let state = active.interactionState {
            lastTabActivationUsedInteractionStateForQA = true
            runtime.restoreInteractionState(state)
        } else {
            lastTabActivationUsedInteractionStateForQA = false
            runtime.loadURL(active.url)
        }
        if focus { focusBrowserContent() }
        refresh()
        urlField.stringValue = active.url
    }

    var tabModelForBrowserStatePersistence: BrowserTabModel { tabModel }

    private func rebuildTabStrip() {
        let signature = tabModel.tabs.map { tab -> String in
            let title = tab.title.isEmpty ? (URL(string: tab.url)?.host ?? tab.url) : tab.title
            return "\(tab.id.uuidString)|\(title)|\(tab.id == tabModel.activeTabId)"
        }
        guard signature != tabStripRenderSignature else { return }
        tabStripRenderSignature = signature
        tabStrip.setViews([], in: .leading)
        tabButtonIds.removeAll()
        for (index, tab) in tabModel.tabs.enumerated() {
            let title = tab.title.isEmpty ? (URL(string: tab.url)?.host ?? tab.url) : tab.title
            let button = NSButton(title: title.isEmpty ? "Browser" : title, target: self, action: #selector(handleSelectTab(_:)))
            button.tag = index
            tabButtonIds[index] = tab.id
            button.bezelStyle = tab.id == tabModel.activeTabId ? .regularSquare : .texturedRounded
            tabStrip.addArrangedSubview(button)
        }
        tabStrip.addArrangedSubview(newTabButton)
        tabStrip.addArrangedSubview(closeTabButton)
    }

    private func refresh() {
        refreshBrowserProfileLabel()
        // Don't clobber a URL the user is actively typing.
        if urlField.currentEditor() == nil {
            urlField.stringValue = runtime.url
        }
        rebuildTabStrip()
        let active = tabModel.activeTab
        let displayTitle = active.title.isEmpty ? (active.url.isEmpty ? "Browser" : active.url) : active.title
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
    @objc private func handleNewTab(_ sender: Any?) {
        snapshotActiveTabFromRuntime()
        _ = tabModel.appendTab(url: DefaultBrowserURL.fallback, title: "")
        onTabModelChange?(tabModel)
        loadOrRestoreActiveTab()
    }

    @objc private func handleCloseTab(_ sender: Any?) {
        tabModel.close(tabId: tabModel.activeTabId)
        onTabModelChange?(tabModel)
        loadOrRestoreActiveTab()
    }

    @objc private func handleSelectTab(_ sender: NSButton) {
        guard let id = tabButtonIds[sender.tag], id != tabModel.activeTabId else { return }
        snapshotActiveTabFromRuntime()
        tabModel.activate(tabId: id)
        onTabModelChange?(tabModel)
        loadOrRestoreActiveTab()
    }

    @objc private func handleFindPrevious(_ sender: Any?) { performFind(direction: .backward) }
    @objc private func handleFindNext(_ sender: Any?) { performFind(direction: .forward) }
    @objc private func handleFindClose(_ sender: Any?) { hideFindBar() }

    func showFindBar() {
        findRowHeightConstraint.constant = 24
        findRow.isHidden = false
        window?.makeFirstResponder(findField)
    }

    // MARK: - Tile-action entry points (A4)
    // Run the same code the toolbar buttons / URL field do, so a focused-tile
    // chord (⌘F/⌘L/⌘R/⌘[/⌘]) executes through one path with the UI.

    /// `⌘F` — reveal + focus the find bar.
    func performFindAction() { showFindBar() }

    /// `⌘R` — reload current page (mirrors the reload button).
    func performReloadAction() { runtime.reload() }

    /// `⌘[` — navigate back (mirrors the back button).
    func performBackAction() { runtime.goBack() }

    /// `⌘]` — navigate forward (mirrors the forward button).
    func performForwardAction() { runtime.goForward() }

    #if ARRAY_FILM
    /// Film build only: the address field, for a pointer target.
    var filmURLField: NSView { urlField }
    #endif

    /// `⌘L` — focus + select the URL field for editing.
    func focusURLField() {
        window?.makeFirstResponder(urlField)
        urlField.currentEditor()?.selectAll(nil)
    }

    /// QA: true while the URL field (or its field editor) holds first responder.
    var urlFieldHasFocusForQA: Bool {
        window?.firstResponder === urlField.currentEditor() || window?.firstResponder === urlField
    }

    var restoredTabSnapshotForQA: (count: Int, activeTabId: UUID, activeURL: String, activeTitle: String, titles: [String]) {
        let active = tabModel.activeTab
        return (tabModel.tabs.count, tabModel.activeTabId, active.url, active.title, tabModel.tabs.map(\.title))
    }

    func selectTabForQA(tabId: UUID) {
        guard tabModel.tabs.contains(where: { $0.id == tabId }), tabId != tabModel.activeTabId else { return }
        snapshotActiveTabFromRuntime()
        tabModel.activate(tabId: tabId)
        onTabModelChange?(tabModel)
        loadOrRestoreActiveTab(focus: false)
    }

    private func hideFindBar() {
        findRow.isHidden = true
        findRowHeightConstraint.constant = 0
        clearFindResult()
        focusBrowserContent()
    }

    private func performFind(direction: BrowserFindDirection) {
        runtime.find(findField.stringValue, direction: direction)
    }

    /// Reflects the runtime's `WKFindResult.matchFound`: "No matches" when none,
    /// cleared on a match. No "N of M" count — WKFindResult exposes no public
    /// total (a real count is deferred; it needs injected JS to tally matches).
    private func showFindResult(matchFound: Bool) {
        findResultLabel.stringValue = matchFound ? "" : "No matches"
    }

    private func clearFindResult() {
        findResultLabel.stringValue = ""
    }

    /// The shared choice control exposes the current driver and explicit user
    /// actions without adding a second, platform-styled menu to the tile.
    func setAgentControl(name: String, colour: NSColor?, engaged: Bool, userDriving: Bool,
                         takeControl: @escaping () -> Void, revealAgent: @escaping () -> Void,
                         close: @escaping () -> Void) {
        let visible = engaged || userDriving || !browserActivityLines.isEmpty
        agentControlButton.isHidden = !visible
        guard visible else { agentControlTitleForQA = nil; return }
        let title = userDriving ? "You’re driving" : (engaged ? "Driven by \(name)" : "Browser activity")
        agentControlTitleForQA = title
        agentControlActions = (userDriving || !engaged ? [] : [ChoiceItem(id: "take", title: "Take control")]) + [
            ChoiceItem(id: "reveal", title: "Reveal agent"), ChoiceItem(id: "close", title: "Close browser", destructive: true)
        ]
        agentControlButton.leadingSwatches = colour.map { [$0] } ?? []
        agentControlButton.onSelection = { item in
            switch item.id {
            case "take": takeControl()
            case "reveal": revealAgent()
            case "close": close()
            default: break
            }
        }
        refreshBrowserActivityMenu()
    }

    func setBrowserActivity(_ lines: [String]) {
        browserActivityLines = Array(lines.suffix(8).reversed())
        refreshBrowserActivityMenu()
    }

    private func refreshBrowserActivityMenu() {
        var activity = browserActivityLines.enumerated().map { index, line in
            ChoiceItem(id: "activity-\(index)", title: line, enabled: false)
        }
        if !activity.isEmpty { activity[0].separatorBefore = true }
        agentControlButton.items = agentControlActions + activity
        if let title = agentControlTitleForQA { agentControlButton.setPresentationTitle(title) }
    }

    func qaChooseAgentControl(_ id: String) {
        guard let item = agentControlButton.items.first(where: { $0.id == id }) else { return }
        agentControlButton.handleSelection(item)
    }

    func refreshBrowserProfileLabel() {
        let activeId = activeBrowserProfileProvider?() ?? tile.metadata.browserProfileId ?? BrowserProfile.defaultProfileId
        profileMenuButton.items = browserProfileChoices()
        profileMenuButton.selectedID = activeId.uuidString
    }

    func browserProfileChoices() -> [ChoiceItem] {
        let profiles = RegistrySettings.normalizedBrowserProfilesForApp(browserProfilesProvider?() ?? [])
        let activeId = activeBrowserProfileProvider?() ?? tile.metadata.browserProfileId ?? BrowserProfile.defaultProfileId
        var items = profiles.map { ChoiceItem(id: $0.id.uuidString, title: $0.name) }
        var create = ChoiceItem(id: "create", title: "Create Profile…")
        create.separatorBefore = true
        items.append(create)
        if !BrowserProfile.isBuiltIn(activeId) {
            items.append(ChoiceItem(id: "rename", title: "Rename Current Profile…"))
            items.append(ChoiceItem(id: "delete", title: "Delete Current Profile…", destructive: true))
        }
        if activeId == BrowserProfile.agentsProfileId {
            items.append(ChoiceItem(id: "signOut", title: "Sign out of everything", destructive: true))
        }
        return items
    }

    func chooseBrowserProfile(_ item: ChoiceItem) {
        guard browserProfileChoices().contains(where: { $0.id == item.id }) else { return }
        let activeId = activeBrowserProfileProvider?() ?? tile.metadata.browserProfileId ?? BrowserProfile.defaultProfileId
        if let id = UUID(uuidString: item.id) { onSwitchBrowserProfile?(id) }
        else {
            switch item.id {
            case "create": onCreateBrowserProfile?()
            case "rename": onRenameBrowserProfile?(activeId)
            case "delete": onDeleteBrowserProfile?(activeId)
            case "signOut": onSignOutAgents?()
            default: break
            }
        }
        refreshBrowserProfileLabel()
    }

    private func focusBrowserContent() {
        runtime.focus()
    }

    var browserContentHasFocusForQA: Bool {
        runtime.isSemanticContentResponder(window?.firstResponder)
    }

    func captureDOMSnapshotForInspector(completion: @escaping (Result<BrowserDOMSnapshot, Error>) -> Void) {
        guard let runtime = runtime as? WKWebViewBrowserRuntime else {
            completion(.failure(Self.inspectorRuntimeError("live browser runtime is unavailable")))
            return
        }
        runtime.captureDOMSnapshot(completion: completion)
    }

    func highlightDOMNodeForInspector(path: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let runtime = runtime as? WKWebViewBrowserRuntime else {
            completion(.failure(Self.inspectorRuntimeError("live browser runtime is unavailable")))
            return
        }
        runtime.highlightDOMNode(path: path, durationMilliseconds: 1_500, completion: completion)
    }

    func captureComputedStylesForInspector(path: String, completion: @escaping (Result<BrowserComputedStyleSnapshot, Error>) -> Void) {
        guard let runtime = runtime as? WKWebViewBrowserRuntime else {
            completion(.failure(Self.inspectorRuntimeError("live browser runtime is unavailable")))
            return
        }
        runtime.captureComputedStyles(path: path, completion: completion)
    }

    func consoleLogEntriesForInspector() -> [BrowserConsoleLogEntry]? {
        guard let runtime = runtime as? WKWebViewBrowserRuntime else { return nil }
        return runtime.consoleLogEntries
    }

    func networkLiteEventsForInspector() -> [BrowserNetworkLiteEvent]? {
        guard let runtime = runtime as? WKWebViewBrowserRuntime else { return nil }
        return runtime.networkLiteEvents
    }

    @discardableResult
    func clearConsoleLogEntriesForInspector() -> Bool {
        guard let runtime = runtime as? WKWebViewBrowserRuntime else { return false }
        runtime.clearConsoleLogEntries()
        return true
    }

    private static func inspectorRuntimeError(_ message: String) -> NSError {
        NSError(domain: "ContinuumBrowserInspector", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    var chromeURLStringForQA: String { urlField.stringValue }
    var chromeTitleForQA: String { chromeSnapshot?.title ?? "" }
    var chromeFaviconTooltipForQA: String? { faviconLabel.toolTip }
    var chromeProgressForQA: (hidden: Bool, value: Double) { (progressIndicator.isHidden, progressIndicator.doubleValue) }
    var findBarVisibleForQA: Bool { !findRow.isHidden }
    var findRowHeightForQA: CGFloat { findRowHeightConstraint.constant }
    var findFieldHasFocusForQA: Bool { window?.firstResponder === findField.currentEditor() || window?.firstResponder === findField }
    var findResultTextForQA: String { findResultLabel.stringValue }
    var tabStripVisibleForQA: Bool { !tabStrip.isHidden }
    var tabCountForQA: Int { tabModel.tabs.count }
    var activeTabTitleForQA: String { tabModel.activeTab.title }
    var activeTabURLForQA: String { tabModel.activeTab.url }
    var activeTabIdForQA: UUID { tabModel.activeTabId }

    func createTabForQA(url: String, title: String) {
        snapshotActiveTabFromRuntime()
        let tab = tabModel.appendTab(url: url, title: title)
        onTabModelChange?(tabModel)
        runtime.loadURL(tab.url)
        refresh()
        urlField.stringValue = tab.url
    }

    func selectTabForQA(_ id: UUID) {
        guard let index = tabModel.tabs.firstIndex(where: { $0.id == id }) else { return }
        let button = NSButton()
        button.tag = index
        tabButtonIds[index] = id
        handleSelectTab(button)
    }

    func closeActiveTabForQA() { handleCloseTab(nil) }

    @discardableResult
    func performURLFieldCommandForQA(_ commandSelector: Selector) -> Bool {
        window?.makeFirstResponder(urlField)
        return control(urlField, textView: NSTextView(), doCommandBy: commandSelector)
    }

    @discardableResult
    func performFindFieldCommandForQA(_ commandSelector: Selector, query: String) -> Bool {
        showFindBar()
        findField.stringValue = query
        return control(findField, textView: NSTextView(), doCommandBy: commandSelector)
    }

    /// QA: mimic the user editing the find field, including the empty-query clear
    /// path (`controlTextDidChange` does not fire on a direct `stringValue` set).
    func setFindQueryForQA(_ query: String) {
        findField.stringValue = query
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: findField))
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
            zPosition: .fromLegacyRank(0),
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
        browserTile.refreshBrowserProfileLabel()
        let choices = browserTile.browserProfileChoices()
        try expect(choices.contains(where: { $0.title == "QA Custom" && $0.id == activeProfileId.uuidString }), "profile choices include active custom profile")
        try expect(choices.contains(where: { $0.title == "Default" }), "profile choices include Default")
        try expect(choices.contains(where: { $0.title == "Agents" }), "profile choices always include Agents")
        for (id, title) in [("create", "Create Profile…"), ("rename", "Rename Current Profile…"), ("delete", "Delete Current Profile…")] {
            try expect(choices.contains(where: { $0.id == id && $0.title == title }), "profile choices include management action")
        }
        for id in ["create", "rename", "delete", BrowserProfile.defaultProfileId.uuidString] {
            browserTile.profileMenuButton.handleSelection(choices.first(where: { $0.id == id })!)
        }
        try expect(switchedProfileId == BrowserProfile.defaultProfileId, "choice switch carries selected profile id")
        try expect(createRequested && renamedProfileId == customProfile.id && deletedProfileId == customProfile.id, "choice management callbacks carry current profile")
        activeProfileId = BrowserProfile.agentsProfileId
        var signedOut = false
        browserTile.onSignOutAgents = { signedOut = true }
        let agentChoices = browserTile.browserProfileChoices()
        try expect(!agentChoices.contains(where: { $0.id == "rename" || $0.id == "delete" }), "Agents cannot be renamed or deleted")
        browserTile.profileMenuButton.handleSelection(agentChoices.first(where: { $0.id == "signOut" })!)
        try expect(signedOut, "Agents sign-out choice reaches its handler")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = browserTile
        window.orderFrontOffscreenForChecks()
        defer {
            runtime.terminate(policy: .requestClose)
            window.close()
        }

        // Render the actual profile trigger and its production choice rows in
        // both appearances, on off-screen fixture windows only.
        let captures = URL(fileURLWithPath: "qa-runs/browser-agents-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        browserTile.refreshBrowserProfileLabel()
        try expect(browserTile.profileMenuButton.selectedID == BrowserProfile.agentsProfileId.uuidString, "header identifies Agents profile")
        browserTile.setAgentControl(name: "Scout", colour: ZoneChromeNSView.color(named: "purple"), engaged: true, userDriving: false,
                                    takeControl: {}, revealAgent: {}, close: {})
        let list = ChoiceListView(items: browserTile.browserProfileChoices(), selectedID: activeProfileId.uuidString)
        list.frame = NSRect(origin: .zero, size: list.intrinsicContentSize)
        let menuWindow = NSWindow(contentRect: list.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        menuWindow.contentView = list
        menuWindow.orderFrontOffscreenForChecks()
        defer { menuWindow.close() }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            menuWindow.appearance = NSAppearance(named: appearance)
            browserTile.profileMenuButton.applyTokens()
            list.applyTokens()
            browserTile.layoutSubtreeIfNeeded()
            list.layoutSubtreeIfNeeded()
            for (suffix, view) in [("header", browserTile.profileMenuButton as NSView), ("menu", list as NSView),
                                   ("browser", browserTile as NSView), ("agent-control", browserTile.agentControlButton as NSView)] {
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw CheckError.failed("profile capture failed")
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: captures.appendingPathComponent(name + "-" + suffix + ".png"))
            }
        }

        browserTile.setAgentControl(name: "Scout", colour: nil, engaged: false, userDriving: false,
                                    takeControl: {}, revealAgent: {}, close: {})
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

        // P0 regression (Cmd-F greyed the screen): web-content focus does not
        // route through TileNSView.mouseUp, so the broker's activeSurface is not
        // the browser tile. The monitor must instead resolve the owning tile
        // from the live first responder and let the tile's Cmd-F claim win.
        let responderTileId = TileNSView.enclosingTileId(of: window.firstResponder)
        try expect(responderTileId == browserTile.tile.id,
            "web-content first responder must resolve to the browser tile for Cmd-F passthrough; got \(String(describing: responderTileId))")
        try expect(browserTile.canHandleReservedShortcut(.focusMode),
            "browser tile must claim Cmd-F so the monitor yields it to the find bar instead of Focus Mode")

        let commandF = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3
        )!
        try expect(browserTile.hostView.performKeyEquivalent(with: commandF), "Cmd-F should be handled from browser host key path")
        try expect(browserTile.findBarVisibleForQA, "Cmd-F should show browser find bar")
        try expect(browserTile.findRowHeightForQA == 24, "visible find bar should reserve exactly one chrome row")
        try expect(browserTile.findFieldHasFocusForQA, "Cmd-F should focus the browser find field")
        try expect(
            browserTile.performFindFieldCommandForQA(#selector(NSResponder.insertNewline(_:)), query: "ready"),
            "Return in find field should run forward find"
        )
        try expect(browserTile.findBarVisibleForQA, "Return in find field should keep find bar open")
        try expect(
            browserTile.performFindFieldCommandForQA(#selector(NSResponder.insertBacktab(_:)), query: "ready"),
            "Shift-Return/backtab in find field should run backward find"
        )
        try expect(
            browserTile.performFindFieldCommandForQA(#selector(NSResponder.cancelOperation(_:)), query: "ready"),
            "Escape in find field should close find bar"
        )
        try expect(!browserTile.findBarVisibleForQA, "Escape should hide browser find bar")
        try expect(browserTile.findRowHeightForQA == 0, "hidden find bar should collapse out of browser content layout")
        try expect(runtime.isSemanticContentResponder(window.firstResponder), "Escape from find should restore browser content focus")

        browserTile.urlField.stringValue = "https://example.test/dirty"
        try expect(
            browserTile.performURLFieldCommandForQA(#selector(NSResponder.cancelOperation(_:))),
            "Escape command should be handled"
        )
        try expect(browserTile.urlField.stringValue == runtime.url, "Escape should restore runtime URL")
        try expect(runtime.isSemanticContentResponder(window.firstResponder), "Escape should leave real WKWebView content focused")
        try expect(window.firstResponder !== browserTile.hostView, "Escape must not focus plain BrowserHostView")
        try expect(webView === window.firstResponder || runtime.isSemanticContentResponder(window.firstResponder), "Escape first responder must be WKWebView or descendant")

        // Addresses typed the way people type them: a dev server, a bare domain, an IP.
        let typed: [(String, String?)] = [
            ("localhost:3000", "http://localhost:3000"),
            ("localhost:5173/docs?x=1", "http://localhost:5173/docs?x=1"),
            ("127.0.0.1:8080", "http://127.0.0.1:8080"),
            ("printer.local", "http://printer.local"),
            ("devbox:4000", "http://devbox:4000"),
            ("example.com/docs", "https://example.com/docs"),
            ("https://example.test/a", "https://example.test/a"),
            ("about:blank", "about:blank"),
            (dataPage, dataPage),
            ("two words", nil),
            ("justaword", nil),
        ]
        for (input, want) in typed {
            let got = BrowserTileNSView.addressBarDestination(input)
            try expect(got == want, "typed address \"\(input.prefix(40))\" must go to \(want ?? "nothing"), got \(got ?? "nothing")")
        }
        browserTile.urlField.stringValue = "localhost:3000"
        try expect(browserTile.performURLFieldCommandForQA(#selector(NSResponder.insertNewline(_:))), "Return command should be handled")
        try expect(runtime.url == "http://localhost:3000", "Return on \"localhost:3000\" must navigate to http://localhost:3000, got \(runtime.url)")
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        // Clear the no-match indicator the moment the find query is emptied so a
        // stale "No matches" never lingers over a blank field.
        guard notification.object as? NSSearchField === findField else { return }
        if findField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clearFindResult()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === findField {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                performFind(direction: .forward)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                performFind(direction: .backward)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                hideFindBar()
                return true
            default:
                return false
            }
        }

        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let next = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !next.isEmpty {
                // This is a real navigation of the active tab, not a title-only
                // refresh. Clear the tab title/snapshot first so chrome falls
                // back to the typed URL until WebKit reports the destination
                // title, instead of keeping the previous page title on the new
                // URL or across app restart. Malformed persisted/user-entered
                // tab URLs degrade to about:blank instead of letting a failed
                // load snapshot the previous tab's URL into this active tab.
                let resolved = Self.addressBarDestination(next)
                let destination = resolved ?? DefaultBrowserURL.fallback
                if resolved == nil { lastInvalidTabURLFallbackForQA = next }
                tabModel.updateActiveTab(url: destination, title: "", faviconURL: nil, interactionState: nil)
                onTabModelChange?(tabModel)
                refresh()
                runtime.loadURL(destination)
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
