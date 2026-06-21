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
    typealias ConsoleLogProvider = () -> [BrowserConsoleLogEntry]?
    typealias ConsoleClearer = () -> Bool

    var onSelectedPanelChange: ((BrowserInspectorPanel) -> Void)?

    private let inspectorState: BrowserInspectorState?
    private let inspectedBrowser: InspectedBrowserSummary?
    private let domSnapshotProvider: DOMSnapshotProvider?
    private let domHighlighter: DOMHighlighter?
    private let consoleLogProvider: ConsoleLogProvider?
    private let consoleClearer: ConsoleClearer?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let panelControl: NSSegmentedControl
    private let refreshButton = NSButton(title: "Refresh DOM", target: nil, action: nil)
    private let consoleClearButton = NSButton(title: "Clear Console", target: nil, action: nil)
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let elementsScrollView = NSScrollView()
    private let elementsStack = NSStackView()
    private let consoleScrollView = NSScrollView()
    private let consoleStack = NSStackView()
    private var selectedPanel: BrowserInspectorPanel
    private var domSnapshot: BrowserDOMSnapshot?
    private var selectedDOMNodeID: String?
    private var elementsMessage: String?

    init(
        tile: Tile,
        inspectorState: BrowserInspectorState?,
        inspectedBrowser: InspectedBrowserSummary?,
        domSnapshotProvider: DOMSnapshotProvider? = nil,
        domHighlighter: DOMHighlighter? = nil,
        consoleLogProvider: ConsoleLogProvider? = nil,
        consoleClearer: ConsoleClearer? = nil
    ) {
        self.inspectorState = inspectorState
        self.inspectedBrowser = inspectedBrowser
        self.domSnapshotProvider = domSnapshotProvider
        self.domHighlighter = domHighlighter
        self.consoleLogProvider = consoleLogProvider
        self.consoleClearer = consoleClearer
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

        let headerStack = NSStackView(views: [titleLabel, detailLabel, statusLabel])
        headerStack.orientation = .vertical
        headerStack.spacing = 3
        headerStack.alignment = .leading
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        body.addSubview(headerStack)
        body.addSubview(panelControl)
        body.addSubview(refreshButton)
        body.addSubview(consoleClearButton)
        body.addSubview(elementsScrollView)
        body.addSubview(consoleScrollView)
        body.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: body.topAnchor, constant: 14),
            headerStack.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),

            panelControl.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 14),
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

            consoleScrollView.topAnchor.constraint(equalTo: consoleClearButton.bottomAnchor, constant: 8),
            consoleScrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            consoleScrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            consoleScrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -16),

            consoleStack.topAnchor.constraint(equalTo: consoleScrollView.contentView.topAnchor),
            consoleStack.leadingAnchor.constraint(equalTo: consoleScrollView.contentView.leadingAnchor),
            consoleStack.trailingAnchor.constraint(greaterThanOrEqualTo: consoleScrollView.contentView.trailingAnchor),

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
    var isDisconnectedForQA: Bool { inspectedBrowser == nil }
    var domSnapshotForQA: BrowserDOMSnapshot? { domSnapshot }
    var selectedDOMNodeIDForQA: String? { selectedDOMNodeID }
    var elementsStatusTextForQA: String { placeholderLabel.stringValue }
    var elementsRefreshEnabledForQA: Bool { refreshButton.isEnabled }
    var consoleRowTextsForQA: [String] { consoleStack.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue } }
    var consoleVisibleRowCountForQA: Int { consoleStack.arrangedSubviews.count }
    var consoleStatusTextForQA: String { placeholderLabel.stringValue }
    var consoleClearEnabledForQA: Bool { consoleClearButton.isEnabled }

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

    func clearConsoleForQA() {
        selectPanelForQA(.console)
        clearConsoleLogEntries()
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
        renderElementsPanel()
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
            return
        }

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
        default:
            refreshButton.isHidden = true
            consoleClearButton.isHidden = true
            elementsScrollView.isHidden = true
            consoleScrollView.isHidden = true
            clearConsoleRows()
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = Self.placeholderText(for: selectedPanel)
        }
    }

    private func renderElementsPanel() {
        guard selectedPanel == .elements else { return }
        refreshButton.isHidden = false
        consoleClearButton.isHidden = true
        consoleScrollView.isHidden = true
        clearConsoleRows()
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

    private func renderConsolePanel() {
        guard selectedPanel == .console else { return }
        refreshButton.isHidden = true
        elementsScrollView.isHidden = true
        consoleClearButton.isHidden = false
        clearElementRows()
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

    private func clearConsoleRows() {
        for view in consoleStack.arrangedSubviews {
            consoleStack.removeArrangedSubview(view)
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
            return "Styles panel placeholder — read-only computed styles arrive in I04."
        case .network:
            return "Network panel placeholder — navigation/download event log arrives in I05."
        }
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
