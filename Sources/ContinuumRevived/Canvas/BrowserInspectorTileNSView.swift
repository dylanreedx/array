import AppKit
import ContinuumRevivedCore
import Foundation

/// Continuum-native inspector shell for one browser tile. This is intentionally
/// not Safari/WebKit's native inspector: it is a normal tile that stores a typed
/// BrowserInspectorState relationship and shows placeholder panels until later
/// inspector tickets wire real DOM/log/style/network data.
@MainActor
final class BrowserInspectorTileNSView: TileNSView {
    struct InspectedBrowserSummary: Equatable {
        var tileId: UUID
        var title: String
        var url: String?
    }

    var onSelectedPanelChange: ((BrowserInspectorPanel) -> Void)?

    private let inspectorState: BrowserInspectorState?
    private let inspectedBrowser: InspectedBrowserSummary?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let panelControl: NSSegmentedControl
    private let placeholderLabel = NSTextField(labelWithString: "")
    private var selectedPanel: BrowserInspectorPanel

    init(tile: Tile, inspectorState: BrowserInspectorState?, inspectedBrowser: InspectedBrowserSummary?) {
        self.inspectorState = inspectorState
        self.inspectedBrowser = inspectedBrowser
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

        placeholderLabel.font = .systemFont(ofSize: 13)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.maximumNumberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerStack = NSStackView(views: [titleLabel, detailLabel, statusLabel])
        headerStack.orientation = .vertical
        headerStack.spacing = 3
        headerStack.alignment = .leading
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        body.addSubview(headerStack)
        body.addSubview(panelControl)
        body.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: body.topAnchor, constant: 14),
            headerStack.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),

            panelControl.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 14),
            panelControl.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            panelControl.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor, constant: -16),

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

    func selectPanelForQA(_ panel: BrowserInspectorPanel) {
        panelControl.selectedSegment = Self.segmentIndex(for: panel)
        applySelectedPanel(panel, notify: true)
    }

    @objc private func panelControlChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0, sender.selectedSegment < BrowserInspectorPanel.allCases.count else { return }
        applySelectedPanel(BrowserInspectorPanel.allCases[sender.selectedSegment], notify: true)
    }

    private func applySelectedPanel(_ panel: BrowserInspectorPanel, notify: Bool) {
        guard selectedPanel != panel else { return }
        selectedPanel = panel
        refreshPanelPlaceholder()
        if notify { onSelectedPanelChange?(panel) }
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
        placeholderLabel.stringValue = Self.placeholderText(for: selectedPanel)
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
            return "Elements panel placeholder — DOM snapshot arrives in I02."
        case .console:
            return "Console panel placeholder — display-only logs arrive in I03."
        case .styles:
            return "Styles panel placeholder — read-only computed styles arrive in I04."
        case .network:
            return "Network panel placeholder — navigation/download event log arrives in I05."
        }
    }

    private static func displayName(title: String, url: String?) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        if let url, let host = URL(string: url)?.host, !host.isEmpty { return host }
        return "Browser"
    }
}
