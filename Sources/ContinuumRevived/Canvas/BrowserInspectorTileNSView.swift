import AppKit
import ContinuumRevivedCore
import Foundation

/// Continuum-native inspector shell for one browser tile. This is intentionally
/// not Safari/WebKit's native inspector: it is a normal tile that stores a typed
/// BrowserInspectorState relationship and surfaces bounded, read-only inspector
/// data through Continuum-owned hooks.
@MainActor
final class BrowserInspectorTileNSView: TileNSView {
    struct InspectedBrowserSummary: Equatable {
        var tileId: UUID
        var title: String
        var url: String?
    }

    typealias DOMSnapshotProvider = (@escaping (Result<BrowserDOMSnapshot, Error>) -> Void) -> Void
    typealias DOMHighlighter = (String, @escaping (Result<Bool, Error>) -> Void) -> Void
    typealias ComputedStyleProvider = (String, @escaping (Result<BrowserComputedStyleSnapshot, Error>) -> Void) -> Void
    typealias ConsoleLogProvider = () -> [BrowserConsoleLogEntry]?
    typealias ConsoleClearer = () -> Bool
    typealias NetworkLiteEventProvider = () -> [BrowserNetworkLiteEvent]?

    var onSelectedPanelChange: ((BrowserInspectorPanel) -> Void)?
    var onRevealBrowser: (() -> Void)?

    private let inspectorState: BrowserInspectorState?
    private var inspectedBrowser: InspectedBrowserSummary?
    private let domSnapshotProvider: DOMSnapshotProvider?
    private let domHighlighter: DOMHighlighter?
    private let computedStyleProvider: ComputedStyleProvider?
    private let consoleLogProvider: ConsoleLogProvider?
    private let consoleClearer: ConsoleClearer?
    private let networkLiteEventProvider: NetworkLiteEventProvider?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let panelControl: NSSegmentedControl
    private let revealBrowserButton = NSButton(title: "Reveal browser tile", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh DOM", target: nil, action: nil)
    private let consoleClearButton = NSButton(title: "Clear Console", target: nil, action: nil)
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let elementsScrollView = NSScrollView()
    private let elementsStack = NSStackView()
    private let stylesScrollView = NSScrollView()
    private let stylesStack = NSStackView()
    private let consoleScrollView = NSScrollView()
    private let consoleStack = NSStackView()
    private let networkScrollView = NSScrollView()
    private let networkStack = NSStackView()
    private var selectedPanel: BrowserInspectorPanel
    private var domSnapshot: BrowserDOMSnapshot?
    private var selectedDOMNodeID: String?
    private var computedStyleSnapshot: BrowserComputedStyleSnapshot?
    private var elementsMessage: String?
    private var stylesMessage: String?

    init(
        tile: Tile,
        inspectorState: BrowserInspectorState?,
        inspectedBrowser: InspectedBrowserSummary?,
        domSnapshotProvider: DOMSnapshotProvider? = nil,
        domHighlighter: DOMHighlighter? = nil,
        computedStyleProvider: ComputedStyleProvider? = nil,
        consoleLogProvider: ConsoleLogProvider? = nil,
        consoleClearer: ConsoleClearer? = nil,
        networkLiteEventProvider: NetworkLiteEventProvider? = nil
    ) {
        self.inspectorState = inspectorState
        self.inspectedBrowser = inspectedBrowser
        self.domSnapshotProvider = domSnapshotProvider
        self.domHighlighter = domHighlighter
        self.computedStyleProvider = computedStyleProvider
        self.consoleLogProvider = consoleLogProvider
        self.consoleClearer = consoleClearer
        self.networkLiteEventProvider = networkLiteEventProvider
        self.selectedPanel = inspectorState?.selectedPanel ?? .elements
        self.panelControl = NSSegmentedControl(
            labels: BrowserInspectorPanel.allCases.map(Self.label(for:)),
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        super.init(tile: tile)

        let body = NSView()
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor(red: 0.08, green: 0.11, blue: 0.13, alpha: 1).cgColor

        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        panelControl.target = self
        panelControl.action = #selector(panelControlChanged(_:))
        panelControl.segmentStyle = .rounded
        panelControl.translatesAutoresizingMaskIntoConstraints = false
        panelControl.selectedSegment = Self.segmentIndex(for: selectedPanel)

        revealBrowserButton.target = self
        revealBrowserButton.action = #selector(revealBrowserButtonClicked(_:))
        revealBrowserButton.bezelStyle = .rounded
        revealBrowserButton.translatesAutoresizingMaskIntoConstraints = false

        refreshButton.target = self
        refreshButton.action = #selector(refreshButtonClicked(_:))
        refreshButton.bezelStyle = .rounded
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        consoleClearButton.target = self
        consoleClearButton.action = #selector(consoleClearButtonClicked(_:))
        consoleClearButton.bezelStyle = .rounded
        consoleClearButton.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.maximumNumberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        elementsStack.orientation = .vertical
        elementsStack.spacing = 2
        elementsStack.alignment = .leading
        elementsStack.distribution = .fill
        elementsStack.translatesAutoresizingMaskIntoConstraints = false

        elementsScrollView.drawsBackground = false
        elementsScrollView.hasVerticalScroller = true
        elementsScrollView.hasHorizontalScroller = true
        elementsScrollView.borderType = .noBorder
        elementsScrollView.documentView = elementsStack
        elementsScrollView.translatesAutoresizingMaskIntoConstraints = false

        stylesStack.orientation = .vertical
        stylesStack.spacing = 4
        stylesStack.alignment = .leading
        stylesStack.distribution = .fill
        stylesStack.translatesAutoresizingMaskIntoConstraints = false

        stylesScrollView.drawsBackground = false
        stylesScrollView.hasVerticalScroller = true
        stylesScrollView.hasHorizontalScroller = true
        stylesScrollView.borderType = .noBorder
        stylesScrollView.documentView = stylesStack
        stylesScrollView.translatesAutoresizingMaskIntoConstraints = false

        consoleStack.orientation = .vertical
        consoleStack.spacing = 4
        consoleStack.alignment = .leading
        consoleStack.distribution = .fill
        consoleStack.translatesAutoresizingMaskIntoConstraints = false

        consoleScrollView.drawsBackground = false
        consoleScrollView.hasVerticalScroller = true
        consoleScrollView.hasHorizontalScroller = true
        consoleScrollView.borderType = .noBorder
        consoleScrollView.documentView = consoleStack
        consoleScrollView.translatesAutoresizingMaskIntoConstraints = false

        networkStack.orientation = .vertical
        networkStack.spacing = 4
        networkStack.alignment = .leading
        networkStack.distribution = .fill
        networkStack.translatesAutoresizingMaskIntoConstraints = false

        networkScrollView.drawsBackground = false
        networkScrollView.hasVerticalScroller = true
        networkScrollView.hasHorizontalScroller = true
        networkScrollView.borderType = .noBorder
        networkScrollView.documentView = networkStack
        networkScrollView.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [titleLabel, detailLabel, statusLabel])
        headerStack.orientation = .vertical
        headerStack.spacing = 3
        headerStack.alignment = .leading
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        revealBrowserButton.setContentHuggingPriority(.required, for: .horizontal)
        revealBrowserButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [headerStack, revealBrowserButton])
        headerRow.orientation = .horizontal
        headerRow.spacing = 12
        headerRow.alignment = .top
        headerRow.distribution = .fill
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        body.addSubview(headerRow)
        body.addSubview(panelControl)
        body.addSubview(refreshButton)
        body.addSubview(consoleClearButton)
        body.addSubview(elementsScrollView)
        body.addSubview(stylesScrollView)
        body.addSubview(consoleScrollView)
        body.addSubview(networkScrollView)
        body.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: body.topAnchor, constant: 14),
            headerRow.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            headerRow.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),

            panelControl.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 14),
            panelControl.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            panelControl.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor, constant: -16),

            refreshButton.topAnchor.constraint(equalTo: panelControl.bottomAnchor, constant: 12),
            refreshButton.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),

            consoleClearButton.topAnchor.constraint(equalTo: panelControl.bottomAnchor, constant: 12),
            consoleClearButton.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),

            elementsScrollView.topAnchor.constraint(equalTo: refreshButton.bottomAnchor, constant: 8),
            elementsScrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            elementsScrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            elementsScrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -16),

            elementsStack.topAnchor.constraint(equalTo: elementsScrollView.contentView.topAnchor),
            elementsStack.leadingAnchor.constraint(equalTo: elementsScrollView.contentView.leadingAnchor),
            elementsStack.trailingAnchor.constraint(greaterThanOrEqualTo: elementsScrollView.contentView.trailingAnchor),

            stylesScrollView.topAnchor.constraint(equalTo: panelControl.bottomAnchor, constant: 12),
            stylesScrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            stylesScrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            stylesScrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -16),

            stylesStack.topAnchor.constraint(equalTo: stylesScrollView.contentView.topAnchor),
            stylesStack.leadingAnchor.constraint(equalTo: stylesScrollView.contentView.leadingAnchor),
            stylesStack.trailingAnchor.constraint(greaterThanOrEqualTo: stylesScrollView.contentView.trailingAnchor),

            consoleScrollView.topAnchor.constraint(equalTo: consoleClearButton.bottomAnchor, constant: 8),
            consoleScrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            consoleScrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            consoleScrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -16),

            consoleStack.topAnchor.constraint(equalTo: consoleScrollView.contentView.topAnchor),
            consoleStack.leadingAnchor.constraint(equalTo: consoleScrollView.contentView.leadingAnchor),
            consoleStack.trailingAnchor.constraint(greaterThanOrEqualTo: consoleScrollView.contentView.trailingAnchor),

            networkScrollView.topAnchor.constraint(equalTo: panelControl.bottomAnchor, constant: 12),
            networkScrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            networkScrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            networkScrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -16),

            networkStack.topAnchor.constraint(equalTo: networkScrollView.contentView.topAnchor),
            networkStack.leadingAnchor.constraint(equalTo: networkScrollView.contentView.leadingAnchor),
            networkStack.trailingAnchor.constraint(greaterThanOrEqualTo: networkScrollView.contentView.trailingAnchor),

            placeholderLabel.topAnchor.constraint(equalTo: panelControl.bottomAnchor, constant: 20),
            placeholderLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24),
            placeholderLabel.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            placeholderLabel.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor, constant: -24),
            placeholderLabel.centerXAnchor.constraint(equalTo: body.centerXAnchor)
        ])

        setContentView(body)
        refreshHeader()
        refreshPanelPlaceholder()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var selectedPanelForQA: BrowserInspectorPanel { selectedPanel }
    var headerTitleForQA: String { titleLabel.stringValue }
    var headerDetailForQA: String { detailLabel.stringValue }
    var revealBrowserEnabledForQA: Bool { revealBrowserButton.isEnabled }
    var isDisconnectedForQA: Bool { inspectedBrowser == nil }
    var domSnapshotForQA: BrowserDOMSnapshot? { domSnapshot }
    var selectedDOMNodeIDForQA: String? { selectedDOMNodeID }
    var computedStyleSnapshotForQA: BrowserComputedStyleSnapshot? { computedStyleSnapshot }
    var elementsStatusTextForQA: String { placeholderLabel.stringValue }
    var elementsRefreshEnabledForQA: Bool { refreshButton.isEnabled }
    var stylesStatusTextForQA: String { placeholderLabel.stringValue }
    var stylesRowTextsForQA: [String] { stylesStack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue } }
    var consoleRowTextsForQA: [String] { consoleStack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue } }
    var consoleVisibleRowCountForQA: Int { consoleStack.arrangedSubviews.count }
    var consoleStatusTextForQA: String { placeholderLabel.stringValue }
    var consoleClearEnabledForQA: Bool { consoleClearButton.isEnabled }
    var networkRowTextsForQA: [String] { networkStack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue } }
    var networkVisibleRowCountForQA: Int { networkStack.arrangedSubviews.count }
    var networkStatusTextForQA: String { placeholderLabel.stringValue }

    func selectPanelForQA(_ panel: BrowserInspectorPanel) {
        panelControl.selectedSegment = Self.segmentIndex(for: panel)
        applySelectedPanel(panel, notify: true)
    }

    func refreshElementsForQA(completion: @escaping (Result<BrowserDOMSnapshot, Error>) -> Void) {
        selectPanelForQA(.elements)
        refreshDOMSnapshot(completion: completion)
    }

    func selectDOMNodeForQA(id: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        selectPanelForQA(.elements)
        selectDOMNode(id: id, completion: completion)
    }

    func refreshSelectedNodeStylesForQA(completion: @escaping (Result<BrowserComputedStyleSnapshot, Error>) -> Void) {
        selectPanelForQA(.styles)
        refreshComputedStylesForSelectedNode(completion: completion)
    }

    func clearConsoleForQA() {
        selectPanelForQA(.console)
        clearConsoleLogEntries()
    }

    func revealBrowserForQA() {
        revealBrowserButtonClicked(nil)
    }

    func updateInspectedBrowser(_ summary: InspectedBrowserSummary?) {
        inspectedBrowser = summary
        refreshHeader()
        refreshPanelPlaceholder()
    }

    override func makeAdditionalTitleBarMenuItems() -> [NSMenuItem] {
        let reveal = NSMenuItem(title: "Reveal Inspected Browser", action: #selector(revealBrowserFromMenu(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.isEnabled = revealBrowserButton.isEnabled
        return [reveal]
    }

    @objc private func revealBrowserFromMenu(_ sender: Any?) {
        onRevealBrowser?()
    }

    @objc private func panelControlChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0, sender.selectedSegment < BrowserInspectorPanel.allCases.count else { return }
        applySelectedPanel(BrowserInspectorPanel.allCases[sender.selectedSegment], notify: true)
    }

    @objc private func refreshButtonClicked(_ sender: NSButton) {
        refreshDOMSnapshot(completion: nil)
    }

    @objc private func consoleClearButtonClicked(_ sender: NSButton) {
        clearConsoleLogEntries()
    }

    @objc private func revealBrowserButtonClicked(_ sender: Any?) {
        onRevealBrowser?()
    }

    @objc private func elementRowSelected(_ sender: NSButton) {
        guard let snapshot = domSnapshot,
              sender.tag >= 0,
              sender.tag < snapshot.nodes.count
        else { return }
        selectDOMNode(id: snapshot.nodes[sender.tag].id, completion: nil)
    }

    private func applySelectedPanel(_ panel: BrowserInspectorPanel, notify: Bool) {
        guard selectedPanel != panel else {
            refreshPanelPlaceholder()
            return
        }
        selectedPanel = panel
        refreshPanelPlaceholder()
        if notify { onSelectedPanelChange?(panel) }
    }

    private func refreshDOMSnapshot(completion: ((Result<BrowserDOMSnapshot, Error>) -> Void)?) {
        guard selectedPanel == .elements else { return }
        guard inspectedBrowser != nil, let domSnapshotProvider else {
            let error = Self.inspectorError("Linked browser tile is disconnected.")
            domSnapshot = nil
            elementsMessage = error.localizedDescription
            renderElementsPanel()
            completion?(.failure(error))
            return
        }

        refreshButton.isEnabled = false
        elementsMessage = "Refreshing DOM snapshot…"
        renderElementsPanel()
        domSnapshotProvider { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.refreshButton.isEnabled = true
                switch result {
                case let .success(snapshot):
                    self.domSnapshot = snapshot
                    self.elementsMessage = nil
                    self.renderElementsPanel()
                    completion?(.success(snapshot))
                case let .failure(error):
                    self.domSnapshot = nil
                    self.elementsMessage = "DOM snapshot unavailable: \(error.localizedDescription)"
                    self.renderElementsPanel()
                    completion?(.failure(error))
                }
            }
        }
    }

    private func selectDOMNode(id: String, completion: ((Result<Bool, Error>) -> Void)?) {
        guard domSnapshot?.nodes.contains(where: { $0.id == id }) == true else {
            let error = Self.inspectorError("DOM node \(id) is not in the current snapshot.")
            completion?(.failure(error))
            return
        }
        selectedDOMNodeID = id
        computedStyleSnapshot = nil
        stylesMessage = nil
        renderElementsPanel()
        refreshComputedStyles(for: id, completion: nil)
        guard let domHighlighter else {
            let error = Self.inspectorError("Linked browser tile is disconnected.")
            completion?(.failure(error))
            return
        }
        domHighlighter(id) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(highlighted):
                    if !highlighted {
                        self.elementsMessage = "Selected node no longer exists in the browser DOM."
                        self.renderElementsPanel()
                    }
                    completion?(.success(highlighted))
                case let .failure(error):
                    self.elementsMessage = "Highlight unavailable: \(error.localizedDescription)"
                    self.renderElementsPanel()
                    completion?(.failure(error))
                }
            }
        }
    }

    private func refreshHeader() {
        guard let inspectedBrowser else {
            titleLabel.stringValue = "Disconnected browser tile"
            if let inspectedBrowserTileId = inspectorState?.inspectedBrowserTileId {
                detailLabel.stringValue = "Inspected browser tile \(inspectedBrowserTileId.uuidString) is missing."
            } else {
                detailLabel.stringValue = "No persisted browser-inspector relationship found."
            }
            statusLabel.stringValue = "Disconnected"
            statusLabel.textColor = .systemOrange
            revealBrowserButton.isEnabled = false
            return
        }

        revealBrowserButton.isEnabled = true
        titleLabel.stringValue = "Inspecting \(Self.displayName(title: inspectedBrowser.title, url: inspectedBrowser.url))"
        detailLabel.stringValue = inspectedBrowser.url?.isEmpty == false ? inspectedBrowser.url! : "No URL saved"
        statusLabel.stringValue = "Linked to browser tile \(inspectedBrowser.tileId.uuidString.prefix(8))"
        statusLabel.textColor = .secondaryLabelColor
    }

    private func refreshPanelPlaceholder() {
        switch selectedPanel {
        case .elements:
            renderElementsPanel()
        case .console:
            renderConsolePanel()
        case .styles:
            renderStylesPanel()
        case .network:
            renderNetworkPanel()
        }
    }

    private func renderElementsPanel() {
        guard selectedPanel == .elements else { return }
        refreshButton.isHidden = false
        consoleClearButton.isHidden = true
        stylesScrollView.isHidden = true
        consoleScrollView.isHidden = true
        networkScrollView.isHidden = true
        clearStyleRows()
        clearConsoleRows()
        clearNetworkRows()
        refreshButton.isEnabled = inspectedBrowser != nil && domSnapshotProvider != nil && refreshButton.isEnabled
        clearElementRows()

        guard inspectedBrowser != nil else {
            refreshButton.isEnabled = false
            elementsScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = elementsMessage ?? "Disconnected — linked browser tile is missing."
            return
        }
        guard domSnapshotProvider != nil else {
            refreshButton.isEnabled = false
            elementsScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "DOM snapshot is unavailable until the live browser runtime is restored."
            return
        }
        if let elementsMessage {
            elementsScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = elementsMessage
            return
        }
        guard let snapshot = domSnapshot else {
            elementsScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "Click Refresh DOM to read a bounded snapshot from the linked WKWebView."
            return
        }
        guard !snapshot.nodes.isEmpty else {
            elementsScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "No element nodes found in the current document."
            return
        }

        placeholderLabel.isHidden = true
        elementsScrollView.isHidden = false
        for (index, node) in snapshot.nodes.enumerated() {
            let button = NSButton(title: Self.rowText(for: node), target: self, action: #selector(elementRowSelected(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            button.setButtonType(.momentaryChange)
            let color: NSColor = node.id == selectedDOMNodeID ? .controlAccentColor : .labelColor
            button.attributedTitle = NSAttributedString(
                string: Self.rowText(for: node),
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: color
                ]
            )
            elementsStack.addArrangedSubview(button)
        }
    }

    private func refreshComputedStylesForSelectedNode(completion: ((Result<BrowserComputedStyleSnapshot, Error>) -> Void)?) {
        guard let selectedDOMNodeID else {
            let error = Self.inspectorError("Select an element before reading computed styles.")
            renderStylesPanel()
            completion?(.failure(error))
            return
        }
        refreshComputedStyles(for: selectedDOMNodeID, completion: completion)
    }

    private func refreshComputedStyles(for nodeID: String, completion: ((Result<BrowserComputedStyleSnapshot, Error>) -> Void)?) {
        guard inspectedBrowser != nil, let computedStyleProvider else {
            let error = Self.inspectorError("Computed styles are unavailable until the linked WKWebView is live.")
            computedStyleSnapshot = nil
            stylesMessage = error.localizedDescription
            renderStylesPanel()
            completion?(.failure(error))
            return
        }

        stylesMessage = "Fetching read-only computed styles…"
        if selectedPanel == .styles { renderStylesPanel() }
        computedStyleProvider(nodeID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(snapshot):
                    guard self.selectedDOMNodeID == snapshot.nodeId else {
                        completion?(.success(snapshot))
                        return
                    }
                    self.computedStyleSnapshot = snapshot
                    self.stylesMessage = nil
                    self.renderStylesPanel()
                    completion?(.success(snapshot))
                case let .failure(error):
                    self.computedStyleSnapshot = nil
                    self.stylesMessage = "Computed styles unavailable: \(error.localizedDescription)"
                    self.renderStylesPanel()
                    completion?(.failure(error))
                }
            }
        }
    }

    private func renderStylesPanel() {
        guard selectedPanel == .styles else { return }
        refreshButton.isHidden = true
        consoleClearButton.isHidden = true
        elementsScrollView.isHidden = true
        consoleScrollView.isHidden = true
        networkScrollView.isHidden = true
        clearElementRows()
        clearConsoleRows()
        clearNetworkRows()
        clearStyleRows()

        guard inspectedBrowser != nil else {
            stylesScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "Disconnected — linked browser tile is missing."
            return
        }
        guard computedStyleProvider != nil else {
            stylesScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "Computed styles are unavailable until the live browser runtime is restored."
            return
        }
        guard selectedDOMNodeID != nil else {
            stylesScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "Select an element in Elements to view read-only computed styles."
            return
        }
        if let stylesMessage {
            stylesScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = stylesMessage
            return
        }
        guard let snapshot = computedStyleSnapshot else {
            stylesScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "Computed styles will appear after selecting an element in Elements."
            return
        }

        placeholderLabel.isHidden = true
        stylesScrollView.isHidden = false
        let rows = Self.styleRows(for: snapshot)
        for row in rows {
            let label = NSTextField(labelWithString: row)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            stylesStack.addArrangedSubview(label)
        }
    }

    private func renderConsolePanel() {
        guard selectedPanel == .console else { return }
        refreshButton.isHidden = true
        elementsScrollView.isHidden = true
        stylesScrollView.isHidden = true
        networkScrollView.isHidden = true
        consoleClearButton.isHidden = false
        clearElementRows()
        clearStyleRows()
        clearNetworkRows()
        clearConsoleRows()

        guard inspectedBrowser != nil else {
            consoleClearButton.isEnabled = false
            consoleScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "Disconnected — linked browser tile is missing."
            return
        }
        guard let consoleLogProvider else {
            consoleClearButton.isEnabled = false
            consoleScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "Console log bridge is unavailable until the live browser runtime is restored."
            return
        }
        guard let entries = consoleLogProvider() else {
            consoleClearButton.isEnabled = false
            consoleScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "Console log bridge is unavailable until the linked WKWebView is live."
            return
        }
        consoleClearButton.isEnabled = !entries.isEmpty && consoleClearer != nil
        guard !entries.isEmpty else {
            consoleScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "No console messages captured from the linked browser yet."
            return
        }

        placeholderLabel.isHidden = true
        consoleScrollView.isHidden = false
        for entry in entries {
            let label = NSTextField(labelWithString: Self.consoleRowText(for: entry))
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = Self.consoleColor(for: entry.level)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
            consoleStack.addArrangedSubview(label)
        }
    }

    private func renderNetworkPanel() {
        guard selectedPanel == .network else { return }
        refreshButton.isHidden = true
        consoleClearButton.isHidden = true
        elementsScrollView.isHidden = true
        stylesScrollView.isHidden = true
        consoleScrollView.isHidden = true
        clearElementRows()
        clearStyleRows()
        clearConsoleRows()
        clearNetworkRows()

        guard inspectedBrowser != nil else {
            networkScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "Disconnected — linked browser tile is missing."
            return
        }
        guard let networkLiteEventProvider else {
            networkScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "Network-lite events are unavailable until the live browser runtime is restored."
            return
        }
        guard let events = networkLiteEventProvider() else {
            networkScrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = "Network-lite events are unavailable until the linked WKWebView is live."
            return
        }

        placeholderLabel.isHidden = true
        networkScrollView.isHidden = false
        addNetworkRow(Self.networkLiteScopeText(), color: .secondaryLabelColor)
        guard !events.isEmpty else {
            addNetworkRow("No navigation, download, or child-window events captured from the linked browser yet.", color: .secondaryLabelColor)
            return
        }
        for event in events {
            addNetworkRow(Self.networkRowText(for: event), color: Self.networkColor(for: event.kind))
        }
    }

    private func addNetworkRow(_ text: String, color: NSColor) {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        networkStack.addArrangedSubview(label)
    }

    private func clearConsoleLogEntries() {
        _ = consoleClearer?()
        renderConsolePanel()
    }

    private func clearElementRows() {
        for view in elementsStack.arrangedSubviews {
            elementsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func clearStyleRows() {
        for view in stylesStack.arrangedSubviews {
            stylesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func clearConsoleRows() {
        for view in consoleStack.arrangedSubviews {
            consoleStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func clearNetworkRows() {
        for view in networkStack.arrangedSubviews {
            networkStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private static func segmentIndex(for panel: BrowserInspectorPanel) -> Int {
        BrowserInspectorPanel.allCases.firstIndex(of: panel) ?? 0
    }

    private static func label(for panel: BrowserInspectorPanel) -> String {
        switch panel {
        case .elements: return "Elements"
        case .console: return "Console"
        case .styles: return "Styles"
        case .network: return "Network"
        }
    }

    private static func placeholderText(for panel: BrowserInspectorPanel) -> String {
        switch panel {
        case .elements:
            return "Click Refresh DOM to read a bounded snapshot from the linked WKWebView."
        case .console:
            return "Console messages from the linked browser WKWebView are displayed here; JavaScript evaluation is not available."
        case .styles:
            return "Select an element in Elements to view read-only computed styles."
        case .network:
            return networkLiteScopeText()
        }
    }

    private static func styleRows(for snapshot: BrowserComputedStyleSnapshot) -> [String] {
        let rect = snapshot.boundingRect
        return [
            "Selected node: \(snapshot.nodeId)",
            "Layout: x=\(formatStyleNumber(rect.x)) y=\(formatStyleNumber(rect.y)) width=\(formatStyleNumber(rect.width)) height=\(formatStyleNumber(rect.height))",
            "Display: \(styleValue("display", in: snapshot))  Position: \(styleValue("position", in: snapshot))  Z: \(styleValue("z-index", in: snapshot))  Overflow: \(styleValue("overflow", in: snapshot))",
            "Size: width=\(styleValue("width", in: snapshot)) height=\(styleValue("height", in: snapshot))",
            "Margin: top=\(styleValue("margin-top", in: snapshot)) right=\(styleValue("margin-right", in: snapshot)) bottom=\(styleValue("margin-bottom", in: snapshot)) left=\(styleValue("margin-left", in: snapshot))",
            "Padding: top=\(styleValue("padding-top", in: snapshot)) right=\(styleValue("padding-right", in: snapshot)) bottom=\(styleValue("padding-bottom", in: snapshot)) left=\(styleValue("padding-left", in: snapshot))",
            "Color: text=\(styleValue("color", in: snapshot)) background=\(styleValue("background-color", in: snapshot))",
            "Font: family=\(styleValue("font-family", in: snapshot)) size=\(styleValue("font-size", in: snapshot)) weight=\(styleValue("font-weight", in: snapshot)) line-height=\(styleValue("line-height", in: snapshot))"
        ]
    }

    private static func styleValue(_ name: String, in snapshot: BrowserComputedStyleSnapshot) -> String {
        snapshot.value(for: name)?.isEmpty == false ? snapshot.value(for: name)! : "—"
    }

    private static func formatStyleNumber(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.2f", value)
    }

    private static func consoleRowText(for entry: BrowserConsoleLogEntry) -> String {
        let timestamp = consoleTimestampString(for: entry.timestamp)
        let urlPart: String
        if let url = entry.url, !url.isEmpty {
            urlPart = " — \(url)"
        } else {
            urlPart = ""
        }
        return "[\(timestamp)] \(entry.level.rawValue.uppercased()) \(entry.message)\(urlPart)"
    }

    private static func networkLiteScopeText() -> String {
        "Network-lite: navigation/download/child-open events only; subresource waterfall unsupported; headers/bodies/timing/replay unavailable."
    }

    private static func networkRowText(for event: BrowserNetworkLiteEvent) -> String {
        let timestamp = consoleTimestampString(for: event.timestamp)
        let status = event.statusCode.map(String.init) ?? "unknown"
        let url = event.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown URL" : event.url
        let errorPart: String
        if let error = event.errorDescription, !error.isEmpty {
            errorPart = " error=\(error)"
        } else {
            errorPart = ""
        }
        return "[\(timestamp)] \(event.kind) method=unknown status=\(status) \(url)\(errorPart)"
    }

    private static func networkColor(for kind: String) -> NSColor {
        switch BrowserNetworkLiteEventKind(rawValue: kind) {
        case .failed: return .systemRed
        case .downloadStarted: return .systemPurple
        case .childOpened: return .systemBlue
        default: return .labelColor
        }
    }

    private static func consoleColor(for level: BrowserConsoleLogLevel) -> NSColor {
        switch level {
        case .error: return .systemRed
        case .warn: return .systemYellow
        case .debug: return .secondaryLabelColor
        case .info: return .systemBlue
        case .log: return .labelColor
        }
    }

    private static func consoleTimestampString(for date: Date) -> String {
        let millisecondsInDay = 86_400_000.0
        let rawMilliseconds = date.timeIntervalSince1970 * 1_000
        let dayMilliseconds = rawMilliseconds.truncatingRemainder(dividingBy: millisecondsInDay)
        let normalized = Int(dayMilliseconds < 0 ? dayMilliseconds + millisecondsInDay : dayMilliseconds)
        let hours = normalized / 3_600_000
        let minutes = (normalized / 60_000) % 60
        let seconds = (normalized / 1_000) % 60
        let milliseconds = normalized % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }

    private static func rowText(for node: BrowserDOMNodeSnapshot) -> String {
        let indent = String(repeating: "  ", count: max(0, node.depth))
        let tag = node.tagName.isEmpty ? node.nodeName.lowercased() : node.tagName
        let idPart = node.idAttribute.map { "#\($0)" } ?? ""
        let classPart: String = {
            guard let className = node.className?.trimmingCharacters(in: .whitespacesAndNewlines), !className.isEmpty else { return "" }
            return "." + className.split(separator: " ").joined(separator: ".")
        }()
        let textPart: String = {
            guard let text = node.textPreview?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return "" }
            return " — \(text)"
        }()
        return "\(indent)<\(tag)\(idPart)\(classPart)>\(textPart)"
    }

    private static func displayName(title: String, url: String?) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        if let url, let host = URL(string: url)?.host, !host.isEmpty { return host }
        return "Browser"
    }

    private static func inspectorError(_ message: String) -> NSError {
        NSError(domain: "ContinuumBrowserInspectorTile", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
