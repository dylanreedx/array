import AppKit
import ContinuumRevivedCore

@MainActor
final class TicketQueueTileNSView: TileNSView {
    private(set) var renderedRowIdentifiers: [String]
    private(set) var emptyStateMessage: String?
    private let dispatchHandler: ((LinearTicketQueueRow) -> Void)?
    private var rowsByIdentifier: [String: LinearTicketQueueRow] = [:]

    init(tile: Tile, rows: [LinearTicketQueueRow] = [], emptyStateMessage: String? = "No Linear API key configured", dispatchHandler: ((LinearTicketQueueRow) -> Void)? = nil) {
        self.renderedRowIdentifiers = rows.map(\.identifier)
        self.emptyStateMessage = rows.isEmpty ? emptyStateMessage : nil
        self.dispatchHandler = dispatchHandler
        self.rowsByIdentifier = Dictionary(uniqueKeysWithValues: rows.map { ($0.identifier, $0) })
        super.init(tile: tile)

        let body = NSStackView()
        body.orientation = .vertical
        body.spacing = 8
        body.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor(red: 0.11, green: 0.15, blue: 0.22, alpha: 1).cgColor

        let header = NSTextField(labelWithString: tile.title)
        header.font = NSFont.boldSystemFont(ofSize: 14)
        header.textColor = .white
        body.addArrangedSubview(header)

        if rows.isEmpty {
            let empty = NSTextField(labelWithString: emptyStateMessage ?? "No tickets")
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            body.addArrangedSubview(empty)
        } else {
            for row in rows {
                let title = "\(row.identifier) · \(row.priority.displayName) · \(row.state) · \(row.title)"
                if dispatchHandler != nil {
                    let button = NSButton(title: title, target: self, action: #selector(dispatchTicket(_:)))
                    button.identifier = NSUserInterfaceItemIdentifier(row.identifier)
                    button.bezelStyle = .inline
                    button.isBordered = false
                    button.alignment = .left
                    button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                    button.contentTintColor = .lightGray
                    button.lineBreakMode = .byTruncatingTail
                    body.addArrangedSubview(button)
                } else {
                    let label = NSTextField(labelWithString: title)
                    label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                    label.textColor = .lightGray
                    label.lineBreakMode = .byTruncatingTail
                    body.addArrangedSubview(label)
                }
            }
        }

        setContentView(body)
    }

    @objc private func dispatchTicket(_ sender: NSButton) {
        guard let rawIdentifier = sender.identifier?.rawValue,
              let row = rowsByIdentifier[rawIdentifier] else { return }
        dispatchHandler?(row)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
